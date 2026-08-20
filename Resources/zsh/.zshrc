# MyTerm zsh shim: .zshrc
#
# See _myterm_common in this directory for why MyTerm routes every zsh startup
# file through here and hands control back after the user's own file runs.
#
# PATH repair below: the user's own .zshrc runs first, and most prompt or
# plugin managers rebuild PATH from scratch. MyTerm's resource directory can
# land anywhere in the result, including below /usr/bin. That is what sends
# web links to Safari instead of to MyTerm, because `open` then resolves to
# /usr/bin/open before it ever reaches MyTerm's copy. Repairing PATH here puts
# MyTerm's copy back in front wherever the user's config left it, which covers
# the scripts and child processes that inherit no shell functions.
#
# The rebuild compares entries as strings rather than matching them as
# patterns. A bundle path can contain zsh pattern characters, which is what
# macOS produces on its own for a second download of the same disk image
# (/Applications/myterm (1).app), and a pattern match silently fails to remove
# the stale entry there.
#
# Both array expansions below are quoted with the (@) flag. A user may set
# SH_WORD_SPLIT in their own .zshrc, which makes an unquoted array expansion
# word-split on whitespace and drop empty components, same as $* everywhere
# else in the shell. Unquoted here, that would corrupt any pre-existing PATH
# entry containing a space rather than just reordering it.

_myterm_dotfile=".zshrc"
if [ -r "${ZDOTDIR:-}/_myterm_common" ]; then
  . "${ZDOTDIR:-}/_myterm_common"
fi

if [ -n "${MYTERM_RESOURCE_DIR:-}" ]; then
  typeset -a _myterm_kept_path
  _myterm_kept_path=()
  for _myterm_entry in "${(@)path}"; do
    if [ "$_myterm_entry" != "$MYTERM_RESOURCE_DIR" ]; then
      _myterm_kept_path+=("$_myterm_entry")
    fi
  done
  path=("$MYTERM_RESOURCE_DIR" "${(@)_myterm_kept_path}")
  export PATH
  unset _myterm_kept_path _myterm_entry
fi
