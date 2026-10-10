# MyTerm zsh shim: .zlogin
#
# See _myterm_common in this directory for why MyTerm routes every zsh startup
# file through here and hands control back after the user's own file runs.

_myterm_dotfile=".zlogin"
if [ -r "${ZDOTDIR:-}/_myterm_common" ]; then
  . "${ZDOTDIR:-}/_myterm_common"
fi

# Login startup may replace the hooks installed by .zshrc.
if (( $+functions[_myterm_shell_ready] )); then
  precmd_functions=("${(@)precmd_functions:#_myterm_shell_ready}" _myterm_shell_ready)
fi
