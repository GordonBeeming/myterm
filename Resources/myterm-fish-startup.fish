# MyTerm fish readiness v1
status is-interactive; or return
set -q MYTERM_STARTUP_TOKEN; or return
set -l myterm_parent_pid (string trim (/bin/ps -o ppid= -p $fish_pid 2>/dev/null))
if test -z "$MYTERM_STARTUP_PARENT_PID"; or not test "x$myterm_parent_pid" = "x$MYTERM_STARTUP_PARENT_PID"
    set -e MYTERM_STARTUP_TOKEN MYTERM_STARTUP_PARENT_PID
    return
end
set -g __myterm_startup_token "$MYTERM_STARTUP_TOKEN"
set -e MYTERM_STARTUP_TOKEN MYTERM_STARTUP_PARENT_PID
functions --copy fish_prompt __myterm_original_fish_prompt; or return
function fish_prompt
    __myterm_original_fish_prompt $argv
    # Release the command after the user's full prompt has rendered.
    builtin printf '\033]7338;%s\007' "$__myterm_startup_token"
    functions --erase fish_prompt
    functions --copy __myterm_original_fish_prompt fish_prompt
    functions --erase __myterm_original_fish_prompt
    set -e __myterm_startup_token
end
