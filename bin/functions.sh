
FATAL(){
	# RHEL echo allows -e (interpret escape sequences).
	# Debian/Ubuntu/et al doesn't as it uses 'dash' as its default shell
	"$ECHO" -e "${FATAL_COLOUR}FATAL $@$NORMAL_COLOUR" >&2

	exit 1
}

WARN(){
	"$ECHO" -e "${WARN_COLOUR}WARN $@$NORMAL_COLOUR" >&2
}

INFO(){
	"$ECHO" -e "${INFO_COLOUR}INFO $@$NORMAL_COLOUR" >&2
}
# Quite long winded, but we need to ensure we don't trample over any customised config
aws_region(){
	local new_aws_region="$1"

	local current_region="`\"$AWS\" --profile \"$AWS_PROFILE\" configure get region`"

	# Do we need to update the config?
	if [ -n "$new_aws_region" -a x"$current_region" != x"$new_aws_region" ]; then
		if ! "$AWS" --profile "$AWS_PROFILE" configure get region | grep -qE "^$new_aws_region"; then
			INFO 'Updating AWS CLI region configuration'
			"$AWS" --profile "$AWS_PROFILE" configure set region "$new_aws_region"
			"$AWS" --profile "$AWS_PROFILE" configure set output text
		fi
	elif [ -z "$new_aws_region" ]; then
		echo "$current_region"
	fi
}

# Quite long winded, but we need to ensure we don't trample over any customised config
aws_credentials(){
	local new_aws_access_key_id="$1"
	local new_aws_secret_access_key="$2"

	if [ -n "$new_aws_access_key_id" ]; then
		if ! "$AWS" --profile "$AWS_PROFILE" configure get aws_access_key_id | grep -qE "^$new_aws_access_key_id"; then
			INFO 'Updating AWS CLI Access Key ID configuration'
			"$AWS" --profile "$AWS_PROFILE" configure set aws_access_key_id "$new_aws_access_key_id"
		fi
	fi
	if [ -n "$new_aws_secret_access_key" ]; then
		if ! "$AWS" --profile "$AWS_PROFILE" configure get aws_secret_access_key | grep -qE "^$new_aws_secret_access_key"; then
			INFO 'Updating AWS CLI Secret Access Key configuration'
			"$AWS" --profile "$AWS_PROFILE" configure set aws_secret_access_key "$new_aws_secret_access_key"
		fi
	fi
}

find_aws(){
	if which aws >/dev/null 2>&1; then
		AWS="`which aws`"

	elif [ -f "$BIN_DIR/aws" ]; then
		AWS="$BIN_DIR/aws"

	else
		FATAL "AWS cli is not installed - did you run '$BASE_DIR/install_deps.sh'?"
	fi
}

stack_exists(){
	local stack_name="$1"

	[ -z "$stack_name" ] && FATAL 'No stack name provided'

	"$AWS" --profile "$AWS_PROFILE" --output text --query "StackSummaries[?StackName == '$stack_name' &&  StackStatus != 'DELETE_COMPLETE'].StackName" \
		cloudformation list-stacks | grep -Eq "^$stack_name"
}

validate_json_files(){
	local failure=0

	for _j in $@; do
		[ -f "$_j" ] || FATAL "File does not exist: '$_j'"

		INFO "Validating JSON: '$_j'"
		python -m json.tool "$_j" >/dev/null || FATAL 'JSON failed to validate'
	done
}

parse_aws_cloudformation_outputs(){
	# We parse the outputs and parameters to build a list of the stack variables - these are then used later on
	# by the Cloudfondry deployment
	local stack="$1"

	[ -z "$stack" ] && FATAL 'No stack name/ARN provided'

	INFO 'Parsing Cloudformation outputs'
	echo '# AWS Stack output variables'
	# Debian's Awk (mawk) doesn't have gensub(), so we can't do this easily/cleanly
	#
	# Basically we convert camelcase variable names to underscore seperated names (eg FooBar -> foo_bar)
	"$AWS" --profile "$AWS_PROFILE" --output text --query 'Stacks[*].[Parameters[*].[ParameterKey,ParameterValue],Outputs[*].[OutputKey,OutputValue]]' \
		cloudformation describe-stacks --stack-name "$stack" | perl -a -F'\t' -ne 'defined($F[1]) || next;
		chomp($F[1]);
		$F[0] =~ s/([a-z0-9])([A-Z])/\1_\2/g;
		$r{$F[0]} = sprintf("%s='\''%s'\''\n",lc($F[0]),$F[1]);
		END{ print $r{$_} foreach(sort(keys(%r))) }'
}

generate_parameters_file(){
	local stack_json="$1"

	[ -n "$stack_json" ] || FATAL 'No Cloudformation stack JSON file provided'
	[ -f "$stack_json" ] || FATAL "Cloudformation stack JSON file does not exist: '$stack_json'"

	echo '['
	for _key in `awk '{if($0 ~ /^  "Parameters"/){ o=1 }else if($0 ~ /^  "/){ o=0} if(o && /^    "/){ gsub("[\"{:]","",$1); print $1 } }' "$stack_json"`; do
		var_name="`echo $_key | perl -ne 's/([a-z0-9])([A-Z])/\1_\2/g; print uc($_)'`"
		eval _param="\$$var_name"

		[ -z "$_param" -o x"$_param" = x'$' ] && continue

		# Correctly indented, Two tabs indentation for HEREDOC
		cat <<EOF
	{ "ParameterKey": "$_key", "ParameterValue": "$_param" }
EOF
		unset var var_name
	done | awk '{ line[++i]=$0 }END{ for(l=1; l<=i; l++){ if(i == l){ print line[l] }else{ printf("%s,\n",line[l]) } } }'
	echo ']'

}

update_parameters_file(){
	local stack_json="$1"
	local parameters_file="$2"

	[ -n "$stack_json" ] || FATAL 'No Cloudformation stack JSON file provided'
	[ -f "$stack_json" ] || FATAL "Cloudformation stack JSON file does not exist: '$stack_json'"
	[ -n "$parameters_file" ] || FATAL 'No Cloudformation parameters file provided'
	[ -f "$parameters_file" ] || FATAL "Cloudformation parameters file does not exist: '$parameters_file'"

	for _key in `awk '{if($0 ~ /^  "Parameters"/){ o=1 }else if($0 ~ /^  "/){ o=0} if(o && /^    "/){ gsub("[\"{:]","",$1); print $1 } }' "$stack_json"`; do
		var_name="`echo $_key | perl -ne 's/([a-z0-9])([A-Z])/\1_\2/g; print uc($_)'`"
		eval _param="\$$var_name"

		[ -z "$_param" -o x"$_param" = x'$' ] && continue

		echo "$_param:$_key" | grep -qE '#' && local separator='@' || local separator='#'

		if ! grep -Eq "{ \"ParameterKey\": \"$_key\", \"ParameterValue\": \"$_param\" }" "$parameters_file"; then
			sed -i $SED_EXTENDED -e "s$separator\"(ParameterKey)\": \"($_param)\", \"(ParameterValue)\": \"[^\"]+\"$separator\"\1\": \"\2\", \"\3\": \"$_key\"${separator}g" \
				"$file"
		fi

		unset var var_name
	done
}

check_cloudformation_stack(){
	local stack_name="$1"

	[ -z "$stack_name" ] && FATAL 'No stack name provided'

	INFO "Checking for existing Cloudformation stack: $stack_name"
	# Is there a better way to query?
	"$AWS" --profile "$AWS_PROFILE" --output text --query \
		"StackSummaries[?StackName == '$stack_name' && (StackStatus == 'CREATE_COMPLETE' || StackStatus == 'UPDATE_COMPLETE' || StackStatus == 'UPDATE_ROLLBACK_COMPLETE')].[StackName]" \
		cloudformation list-stacks | grep -q "^$stack_name$" && INFO "Stack found: $stack_name" || INFO "Stack does not exist: $stack_name"
}

calculate_dns_ip(){
	local stack_outputs="$1"

	[ -z "$stack_outputs" ] && FATAL 'No stack outputs provided'
	[ -f "$stack_outputs" ] || FATAL "Stack outputs file does not exist: $stack_outputs"

	# Add AWS DNS IP: http://docs.aws.amazon.com/AmazonVPC/latest/UserGuide/VPC_DHCP_Options.html#AmazonDNS
	# "... a DNS server running on a reserved IP address at the base of the VPC IPv4 network range, plus two.
	# For example, the DNS Server on a 10.0.0.0/16 network is located at 10.0.0.2."
	#
	# Calculate the decimal version of the VPC CIDR base address then increment by 2 to find the DNS address
	local ip=`awk -F. -v increment=2 '/^vpc_cidr=/{
		gsub("^.*=[\"'\'']?","",$1)
		gsub("/.*$","",$4)

		sum=($1*256^3)+($2*256^2)+($3*256)+$4+increment

		for(i=1; i<=4; i++){
			d[i]=sum%256
			sum-=d[i]
			sum=sum/256
		}

		printf("%d.%d.%d.%d\n",d[4],d[3],d[2],d[1])
	}' "$stack_outputs"`

	[ -z "$ip" ] && FATAL 'Unable to calculate DNS IP'

	grep -qE '^[0-9.]+$' <<EOF || FATAL "Invalid IP: $IP"
$ip
EOF

	echo "dns_ip='$ip'"
}

show_duplicate_output_names(){
	local outputs_dir="$1"

	awk -F= '!/^#/{ a[$1]++ }END{ for(i in a){ if(a[i] > 1) printf("%s=%d\n",i,a[i])}}' "$outputs_dir"/outputs-*.sh
}

bosh_env(){
	local action_option=$1

	"$BOSH" "$action_option" "$BOSH_LITE_MANIFEST_FILE" \
		$BOSH_INTERACTIVE_OPT \
		$BOSH_TTY_OPT \
		--var bosh_name="$DEPLOYMENT_NAME" \
		--var bosh_deployment="$BOSH_DEPLOYMENT" \
		--state="$BOSH_LITE_STATE_FILE" \
		--vars-env="$ENV_PREFIX_NAME" \
		--vars-file="$SSL_YML" \
		--vars-store="$BOSH_LITE_VARS_FILE"
}

cf_app_url(){
	local application="$1"

	[ -z "$application" ] && FATAL 'No application provided'


	# We blindly assume we are logged in and pointing at the right place
	# Sometimes we seem to get urls, sometimes routes?
	"$CF" app "$application" | awk -F" *: *" '/^(urls|routes):/{print $2}'
}



installed_bin(){
	local bin="$1"

	[ -z "$bin" ] && FATAL 'No binary to check'

	[ -f "$BIN_DIR/$bin" ] || FATAL "$bin has not been installed, did you run $BASE_DIR/install_deps.sh?"

	if [ ! -x "$BIN_DIR/$bin" ]; then
		WARN "$bin is not executable - fixing permissions"

		chmod u+x "$BIN_DIR/$bin"
	fi
}

findpath(){
	local return_var="$1"

	[ -z "$2" ] && FATAL 'Not enough parameters provided'
	shift

	local path="$@"

	[ -z "$path" ] && FATAL 'No path to find'
	[ -e "$path" ] || FATAL "Path does not exist: $path"

	local real_dir=

	if which realpath >/dev/null 2>&1; then
		# Newer Linux distributions have realpath
		real_dir="`realpath \"$path\"`"

	elif readlink --version 2>&1 | grep -q 'GNU GPL'; then
		# Older ones should have readlink -k
		real_dir="`readlink -f \"$path\"`"
	fi

	if [ -z "$real_dir" ]; then
		# Everything else falls here
		[ -d "$path" ] || path="`dirname \"$path\"`"

		real_dir="`cd \"$path\" && pwd`"
	fi

	[ x"$return_var" != x"NONE" ] && eval $return_var="\"$real_dir\"" || echo "$real_dir"
}

prefix_vars(){
	local parse_file="$1"
	local env_prefix="$2"

	[ -n "$parse_file" -a x"$parse_file" != x"-" -a ! -f "$parse_file" ] && FATAL "Unable to parse missing file: $parse_file"

	# This should cope with both env_prefix and parse_file being empty
	awk -v env_prefix="$env_prefix" '!/^#/{printf("%s%s\n",env_prefix,$0)}' "$parse_file"
}

generate_password(){
	local length="${1:-16}"
	local tr_filter="${2:-[:alnum:]}"

	head /dev/urandom | tr -dc "$tr_filter" | head -c "$length"
}

load_outputs(){
	local stack_outputs_dir="$1"
	local env_prefix="$2"

	local outputs_dir

	[ -z "$stack_outputs_dir" ] && FATAL 'No stack outputs directory provided'

	# Find the absolute path
	findpath outputs_dir "$stack_outputs_dir"

	[ -d "$outputs_dir" ] || FATAL "Stack outputs directory does not exist: '$outputs_dir'"	

	INFO "Loading outputs"
	for _o in `find "$outputs_dir/" -mindepth 1 -maxdepth 1 "(" -not -name outputs-preamble.sh -and -name \*.sh ")" | awk -F/ '{print $NF}' | sort`; do
		INFO "Loading '$_o'"
		eval export `prefix_vars "$outputs_dir/$_o" "$env_prefix"`
	done
}

load_output_vars(){
	local stack_outputs_dir="$1"
	local env_prefix="$2"

	local outputs_dir

	[ -z "$3" ] && FATAL 'Not enough parameters'
	[ -z "$stack_outputs_dir" ] && FATAL 'No stack outputs directory provided'

	# Find the absolute path
	findpath outputs_dir "$stack_outputs_dir"

	[ -d "$outputs_dir" ] || FATAL "Stack outputs directory does not exist: '$outputs_dir'"

	[ x"$env_prefix" = x"NONE" ] && unset env_prefix
	shift 2

	for _i in $@; do
		eval `grep -hE "^$_i=" "$outputs_dir"/* | prefix_vars - "$env_prefix"`
	done
}

# Hopefully we can run on Linux and Darwin (OSX)
case `uname -s` in
	Darwin)
		ECHO='echo'
		SED_EXTENDED='-E'
		;;
	Linux)
		# Debian & Ubuntu use 'dash' as their shell, which is less than feature complete compared to other shells
		ECHO='/bin/echo'
		SED_EXTENDED='-r'
		;;
esac
