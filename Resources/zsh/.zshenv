# MyTerm zsh shim: .zshenv
#
# See _myterm_common in this directory for why MyTerm routes every zsh startup
# file through here and hands control back after the user's own file runs.
#
# The open() function lives here, not in .zshrc, because `zsh -c` reads only
# .zshenv. An AI coding client's shell tool runs commands that way, so this is
# the one file that has to carry the redirect for that case. A shell function
# is found before anything on PATH, which is what makes the redirect survive a
# user config that rebuilds PATH from scratch.

_myterm_dotfile=".zshenv"
if [ -r "${ZDOTDIR:-}/_myterm_common" ]; then
  . "${ZDOTDIR:-}/_myterm_common"
fi

open() {
  "${MYTERM_OPEN_SHIM:-/usr/bin/open}" "$@"
}
