#!/bin/sh

# use flock(1) from util-linux to avoid seek contention on slow HDDs
# when using multiple `pull_threads' with grok-pull:
# [ "${FLOCKER}" != "$0" ] && exec env FLOCKER="$0" flock "$0" "$0" "$@" || :

# post_update_hook for repos.conf as used by grok-pull, takes a full
# git repo path as it's first and only arg.
full_git_dir="$1"

url_base=http://127.0.0.1:8080/

# same default as other public-inbox-* tools
PI_CONFIG=${PI_CONFIG-~/.public-inbox/config}

# FreeBSD expr(1) only supports BRE, so no '+'
EPOCH2MAIN='\(..*\)/git/[0-9][0-9]*\.git'

# see if it's v2 or v1 based on tree contents, since somebody could
# theoretically name a v1 inbox with a path that looks like a v2 epoch
if git --git-dir="$full_git_dir" ls-tree --name-only HEAD | \
	grep -E '^(m|d)$' >/dev/null
then
	inbox_fmt=2
	inbox_dir=$(expr "$full_git_dir" : "$EPOCH2MAIN")
	inbox_name=$(basename "$inbox_dir")
	msgmap="$inbox_dir"/msgmap.sqlite3
else
	inbox_fmt=1
	inbox_dir="$full_git_dir"
	inbox_name=$(basename "$inbox_dir" .git)
	msgmap="$inbox_dir"/public-inbox/msgmap.sqlite3
fi

# run public-inbox-init iff unconfigured
cfg_dir=$(git config -f "$PI_CONFIG" publicinbox."$inbox_name".inboxdir)

# check legacy name for "inboxdir"
case $cfg_dir in
'') cfg_dir=$(git config -f "$PI_CONFIG" publicinbox."$inbox_name".mainrepo) ;;
esac

case $cfg_dir in
'')
	remote_git_url=$(git --git-dir="$full_git_dir" config remote.origin.url)
	case $remote_git_url in
	'')
		echo >&2 "remote.origin.url unset in $full_git_dir/config"
		exit 1
		;;
	esac

	case $inbox_fmt in
	1)
		remote_inbox_url="$remote_git_url"
		;;
	2)
		remote_inbox_url=$(expr "$remote_git_url" : "$EPOCH2MAIN")
		;;
	esac

	config_url="$remote_inbox_url"/_/text/config/raw
	remote_config="$inbox_dir"/remote.config.$$
	infourls=
	trap 'rm -f "$remote_config"' EXIT
	if curl --compressed -sSf -v "$config_url" >"$remote_config"
	then
		# n.b. inbox_name on the remote may not match our local
		# inbox_name, so we match all addresses in the remote config
		addresses=$(git config -f "$remote_config" -l | \
			sed -ne 's/^publicinbox\..\+\.address=//p')
		case $addresses in
		'')
			echo >&2 'unable to extract address(es) from ' \
				"$remote_config"
			exit 1
			;;
		esac
		newsgroups=$(git config -f "$remote_config" -l | \
			sed -ne 's/^publicinbox\..\+\.newsgroup=//p')
		infourls=$(git config -f "$remote_config" -l | \
			sed -ne 's/^publicinbox\..\+.infourl=//p')
	else
		newsgroups=
		addresses="$inbox_name@$$.$(hostname).example.com"
		echo >&2 "E: curl $config_url failed"
		echo >&2 "E: using bogus <$addresses> for $inbox_dir"
	fi
	local_url="$url_base$inbox_name"
	public-inbox-init -V$inbox_fmt "$inbox_name" \
		"$inbox_dir" "$local_url" $addresses

	if test $? -ne 0
	then
		echo >&2 "E: public-inbox-init failed on $inbox_dir"
		exit 1
	fi

	for ng in $newsgroups
	do
		git config -f "$PI_CONFIG" \
			"publicinbox.$inbox_name.newsgroup" "$ng"
		# only one newsgroup per inbox
		break
	done
	for url in $infourls
	do
		git config -f "$PI_CONFIG" \
			"publicinbox.$inbox_name.infourl" "$url"
	done
	curl -sSfv "$remote_inbox_url"/description >"$inbox_dir"/description
	echo "I: $inbox_name at $inbox_dir ($addresses) $local_url"
	;;
esac

# only run public-inbox-index if an index exists and has messages,
# since epochs may be cloned out-of-order by grokmirror and we also
# don't know what indexlevel a user wants
if test -f "$msgmap"
then
	n=$(echo 'SELECT COUNT(*) FROM msgmap' | sqlite3 -readonly "$msgmap")
	case $n in
	0|'')
		: v2 inboxes may be init-ed with an empty msgmap
		;;
	*)
		# if on HDD and limited RAM, add `-j0' w/ public-inbox 1.6.0+
		$EATMYDATA public-inbox-index -v "$inbox_dir"
		;;
	esac
fi
