# MyTerm zsh shim: .zprofile
#
# See _myterm_common in this directory for why MyTerm routes every zsh startup
# file through here and hands control back after the user's own file runs.

_myterm_dotfile=".zprofile"
if [ -r "${ZDOTDIR:-}/_myterm_common" ]; then
  . "${ZDOTDIR:-}/_myterm_common"
fi
