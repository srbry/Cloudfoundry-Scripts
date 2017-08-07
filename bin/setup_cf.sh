#!/bin/sh
#
#

set -e

BASE_DIR="`dirname \"$0\"`"

DEPLOYMENT_NAME="$1"
EMAIL_ADDRESS="${2:-NONE}"
ORG_NAME="${3:-$organisation}"
TEST_SPACE="${4:-Test}"
DONT_SKIP_SSL_VALIDATION="$5"

. "$BASE_DIR/common.sh"
. "$BASE_DIR/bosh-env.sh"

[ -z "$ORG_NAME" ] && ORG_NAME="$organisation"

eval export `prefix_vars "$PASSWORD_CONFIG_FILE"`

# We don't want any sub-scripts to login
export NO_LOGIN=1

[ -z "$EMAIL_ADDRESS" ] && FATAL 'No email address has been supplied'
[ -n "$DONT_SKIP_SSL_VALIDATION" ] || CF_EXTRA_OPTS='--skip-ssl-validation'
[ -z "$ORG_NAME" ] && FATAL 'No organisation has been set'

findpath TEST_APPS "$BASE_DIR/../test-apps"

# Ensure we have CF available
installed_bin cf

# We may not always want to update the admin user
[ x"$EMAIL_ADDRESS" != x"NONE" ] && "$BASE_DIR/setup_cf-admin.sh" "$DEPLOYMENT_NAME" cf_admin "$EMAIL_ADDRESS"

[ -f "$CF_CREDENTIALS" ] || FATAL "Cannot find CF admin credentials: $CF_CREDENTIALS. Has an admin user been created"

# Pull in newly generated credentials
eval export `prefix_vars "$CF_CREDENTIALS"`

INFO "Setting API target as $api_dns"
"$CF" api "$api_dns" "$CF_EXTRA_OPTS"

INFO "Logging in as $CF_ADMIN_USERNAME"
"$CF" login -u "$CF_ADMIN_USERNAME" -p "$CF_ADMIN_PASSWORD" "$CF_EXTRA_OPTS" </dev/null

"$BASE_DIR/setup_cf-orgspace.sh" "$DEPLOYMENT_NAME" "$ORG_NAME" "$TEST_SPACE"

INFO 'Available buildpacks:'
# Sometimes we get a weird error, but upon next deployment the error doesn't occur...
# Server error, status code: 400, error code: 100001, message: The app is invalid: buildpack staticfile_buildpack is not valid public url or a known buildpack name
"$CF" buildpacks

if [ -z "$SKIP_TESTS" ]; then
	INFO 'Testing application deployment'
	for i in `ls "$TEST_APPS"`; do
		buildpack="`awk '/^ *buildpack:/{print $2}' "$TEST_APPS/$i/manifest.yml"`"

		if [ -n "$buildpack" ]; then
			"$CF" buildpacks | grep -q "^$buildpack" || FATAL "Buildpack '$buildpack' not available - please retry"
		fi

		cd "$TEST_APPS/$i"

		"$BASE_DIR/cf_push.sh" "$DEPLOYMENT_NAME" "$i" "$ORG_NAME" "$TEST_SPACE" "$TEST_APPS/$i"

		"$BASE_DIR/cf_delete.sh" "$DEPLOYMENT_NAME" "$i"

		cd -
	done
fi

INFO 'Setting up RDS broker'
IGNORE_EXISTING=1 "$BASE_DIR/setup_cf-rds-broker.sh" "$DEPLOYMENT_NAME"

INFO 'Setting up RabbitMQ broker'
IGNORE_EXISTING=1 "$BASE_DIR/setup_cf-service-broker.sh" "$DEPLOYMENT_NAME" rabbitmq rabbitmq-broker "$rabbitmq_broker_password" "https://rabbitmq-broker.system.$domain_name"

INFO 'Setting up ElastiCache broker'
IGNORE_EXISTING=1 "$BASE_DIR/setup_cf-elasticache-broker.sh" "$DEPLOYMENT_NAME" elasticache-broker

if [ -d "security_groups" ]; then
	INFO 'Setting up Security Groups'

	for _s in `ls security_groups`; do
		group_name="`echo $security_group | sed $SED_EXTENDED -e 's/\.json$//g'`"
		INFO "... $group_name"

		"$CF" "$group_name" "security_groups/$_s"
	done
fi
