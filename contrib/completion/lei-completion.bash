# Copyright (C) 2020-2021 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# preliminary bash completion support for lei (Local Email Interface)
# Needs a lot of work, see `lei__complete' in lib/PublicInbox::LEI.pm
_lei() {
	case ${COMP_WORDS[@]} in
	*' add-external h'* | *' --mirror h'*)
		compopt -o nospace
		;;
	*) compopt +o nospace ;; # the default
	esac
	COMPREPLY=($(compgen -W "$(lei _complete ${COMP_WORDS[@]})" \
			-- "${COMP_WORDS[COMP_CWORD]}"))
	return 0
}
complete -o default -o bashdefault -F _lei lei
