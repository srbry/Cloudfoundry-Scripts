#!/bin/sh

set -e

echo -n TEST | grep -q -- '^-n TEST$' && ECHO=/bin/echo || ECHO=echo

if [ -z "$FOOT_PROTECTION_DISABLED_AND_I_KNOW_WHY" ] && git branch | grep -Eq '^\* master'; then
	$ECHO "You are on master"
	$ECHO "Are you probably do not want to create copies of the vendored directories on master"
	$ECHO "IF YOU REALLY WANT TO DO THIS AND YOU KNOW EXACTLY WHAT WILL HAPPEN THEN RERUN THIS"
	$ECHO "SCRIPT AS FOLLOWS:"
	$ECHO "$ export FOOT_PROTECTION_DISABLED_AND_I_KNOW_WHY=true $0 $@"

	exit 1
fi
	

for i in ${@:-`ls vendor/`}; do
	$ECHO -n "Git update: $i? (y/N)"
	read update

	if [ x"$update" = x"Y" -o x"$update" = x"y" ]; then
		cd "vendor/$i"

		git pull

		cd -

		$ECHO -n "View differences? (y/N)"
		read view_diff

		if [ x"$view_diff" = x"Y" -o x"$view_diff" = x"y" ]; then
			if diff -Ncrdx .git "vendor/$i" "$i"; then
				echo "No differences"

				continue
			fi
		fi

		$ECHO -n "Edit diff before applying? (y/N)"
		read edit_diff

		if [ x"$edit_diff" = x"Y" -o x"$edit_diff" = x"y" ]; then
			patch="`mktemp "$i.patch.XXXX"`"

			diff -Ncrdx .git "$i" "vendor/$i" >"$patch" || :

			vim "$patch"
		fi

		$ECHO -n "Apply diff? (y/N)"
		read apply_diff

		if [ x"$apply_diff" = x"Y" -o x"$apply_diff" = x"y" ]; then
			if [ -n "$patch" -a -f "$patch" ]; then
				patch -p1 -d "$i" -i "$patch" && rm -f "$patch"
			else
				diff -Ncrdx .git "$i" "vendor/$i" | patch -p1 -d "$i"
			fi
		fi
	fi
done

$ECHO "Git status"
git status 
