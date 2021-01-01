# Copyright (C) 2020 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# preliminary bash completion support for lei (Local Email Interface)
# Needs a lot of work, see `lei__complete' in lib/PublicInbox::LEI.pm
_lei() {
	COMPREPLY=($(compgen -W "$(lei _complete ${COMP_WORDS[@]})" \
			-- "${COMP_WORDS[COMP_CWORD]}"))
	return 0
}
complete -o filenames -o bashdefault -F _lei lei
