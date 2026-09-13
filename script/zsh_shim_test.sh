#!/usr/bin/env bash
# shellcheck disable=SC2016
# The single-quoted strings below are zsh source, handed to zsh in its several forms here
# (-c, -ic, -lic). bash must not expand them: the expansion has to happen in the zsh under
# test, not in this script.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/myterm-zsh-shim.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

RESOURCE_DIR="$SCRATCH_DIR/resources"
FAKE_HOME="$SCRATCH_DIR/home"
JUNK_DIR="$SCRATCH_DIR/junk"
MARKER_FILE="$SCRATCH_DIR/markers.txt"

mkdir -p "$RESOURCE_DIR" "$FAKE_HOME" "$JUNK_DIR"

cp -R "$ROOT_DIR/Resources/zsh" "$RESOURCE_DIR/zsh"
cp "$ROOT_DIR/Resources/open" "$RESOURCE_DIR/open"
cp "$ROOT_DIR/Resources/myterm-browser" "$RESOURCE_DIR/myterm-browser"
chmod +x "$RESOURCE_DIR/open" "$RESOURCE_DIR/myterm-browser"

# The user's own dotfiles. Each one appends a marker line, so we can tell
# they still ran, and each pushes a junk directory ahead of MyTerm's
# resource directory in PATH, reproducing the real bug this test guards
# against.
cat > "$FAKE_HOME/.zshenv" <<EOF
echo "zshenv-ran" >> "$MARKER_FILE"
export PATH="$JUNK_DIR:\$PATH"
EOF

cat > "$FAKE_HOME/.zshrc" <<EOF
echo "zshrc-ran" >> "$MARKER_FILE"
export PATH="$JUNK_DIR:\$PATH"
EOF

cat > "$FAKE_HOME/.zlogout" <<EOF
echo "zlogout-ran" >> "$MARKER_FILE"
EOF

assert_contains() {
  local needle="$1" haystack="$2" description="$3"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    printf 'FAIL: %s\nexpected to find: %s\ngot:\n%s\n' "$description" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1" haystack="$2" description="$3"
  if grep -Fq "$needle" <<<"$haystack"; then
    printf 'FAIL: %s\ndid not expect to find: %s\ngot:\n%s\n' "$description" "$needle" "$haystack" >&2
    exit 1
  fi
}

# Runs zsh with the environment MyTermBrowserLauncher.environment sets for
# a pane: ZDOTDIR pointed at the bundled shim directory, MYTERM_RESOURCE_DIR
# for the PATH repair, MYTERM_OPEN_SHIM for the open() function, and a
# minimal PATH so the fake resource directory's position is easy to see.
run_zsh() {
  env -i \
    HOME="$FAKE_HOME" \
    ZDOTDIR="$RESOURCE_DIR/zsh" \
    MYTERM_RESOURCE_DIR="$RESOURCE_DIR" \
    MYTERM_OPEN_SHIM="$RESOURCE_DIR/open" \
    PATH="/usr/bin:/bin" \
    zsh "$@" </dev/null
}

type_output="$(run_zsh -c 'type open')"
assert_contains "shell function" "$type_output" "'zsh -c type open' must report a shell function, not a PATH lookup"

interactive_type_output="$(run_zsh -lic 'type open' 2>&1)"
assert_contains "shell function" "$interactive_type_output" "'zsh -lic type open' must report a shell function"

# command -v reports a shell function by name, so unset the function first
# to see what a child process that does not inherit shell functions (a
# script, a tool invoked by PATH) would actually resolve. That is what the
# .zshrc PATH repair exists to fix.
command_v_output="$(run_zsh -lic 'unfunction open; command -v open' 2>&1)"
assert_contains "$RESOURCE_DIR/open" "$command_v_output" \
  "'command -v open' without the function must resolve inside the resource directory"
assert_not_contains "/usr/bin/open" "$command_v_output" \
  "'command -v open' without the function must not resolve to /usr/bin/open"

: > "$MARKER_FILE"
run_zsh -lic 'true' >/dev/null 2>&1
markers="$(cat "$MARKER_FILE")"
assert_contains "zshenv-ran" "$markers" "the user's own .zshenv must still run"
assert_contains "zshrc-ran" "$markers" "the user's own .zshrc must still run"

# A login shell reads $ZDOTDIR/.zlogout on exit. _myterm_common re-points
# ZDOTDIR back at the shim directory after .zlogin, so without a .zlogout
# shim there the user's real .zlogout (history flushing, session cleanup)
# would never run.
assert_contains "zlogout-ran" "$markers" "the user's own .zlogout must still run on shell exit"

original_zdotdir_output="$(run_zsh -lic 'printf %s "$MYTERM_ORIGINAL_ZDOTDIR"' 2>&1)"
if [ "$original_zdotdir_output" != "$FAKE_HOME" ]; then
  printf 'FAIL: MYTERM_ORIGINAL_ZDOTDIR was "%s", expected "%s"\n' "$original_zdotdir_output" "$FAKE_HOME" >&2
  exit 1
fi

# A nested zsh started from inside a pane (a script, a tool, a plain `zsh`)
# must inherit ZDOTDIR pointing at the shim directory, or it bypasses every
# shim and its `open` goes to /usr/bin/open. `unset ZDOTDIR` in the shim drops
# the export attribute, so the hand-back has to export it again.
nested_zsh_output="$(run_zsh -ic 'zsh -c "printf \"NESTED_ZDOTDIR=%s\n\" \"\${ZDOTDIR-unset}\"; type open"' 2>&1)"
assert_contains "NESTED_ZDOTDIR=$RESOURCE_DIR/zsh" "$nested_zsh_output" \
  "a nested zsh started from a pane must inherit ZDOTDIR pointing at the shim directory"
assert_contains "shell function" "$nested_zsh_output" \
  "a nested zsh started from a pane must still get the open function from the shim"

# MyTerm is developed inside MyTerm, so a pane can inherit MYTERM_ORIGINAL_ZDOTDIR
# already equal to the shim directory (its own build's baseEnvironment ZDOTDIR was
# the shim directory). Without the self-reference guard, .zshenv would source
# itself as "the user's file" forever.
self_referencing_output="$(
  env -i \
    HOME="$FAKE_HOME" \
    ZDOTDIR="$RESOURCE_DIR/zsh" \
    MYTERM_ORIGINAL_ZDOTDIR="$RESOURCE_DIR/zsh" \
    MYTERM_RESOURCE_DIR="$RESOURCE_DIR" \
    MYTERM_OPEN_SHIM="$RESOURCE_DIR/open" \
    PATH="/usr/bin:/bin" \
    zsh -lic 'type open' </dev/null 2>&1
)"
assert_contains "shell function" "$self_referencing_output" \
  "a self-referencing MYTERM_ORIGINAL_ZDOTDIR must still define open, not recurse"
assert_not_contains "recursion" "$self_referencing_output" \
  "a self-referencing MYTERM_ORIGINAL_ZDOTDIR must not trigger zsh's recursion limiter"

# The shims must be silent. A stray line corrupts the terminal for any tool
# that parses shell output, and the markers above are written to a file rather
# than stdout precisely so this assertion can demand nothing at all.
: > "$MARKER_FILE"
silence_output="$(run_zsh -lic 'true' 2>&1)"
if [ -n "$silence_output" ]; then
  printf 'FAIL: the shims emitted output on a normal login shell:\n%s\n' "$silence_output" >&2
  exit 1
fi

# The zsh function, Resources/open and Resources/myterm-browser are each
# covered on their own elsewhere. This proves they are wired together: a real
# `open <url>` typed in a pane has to reach MYTERM_OPEN_SHIM with the URL
# intact. A mismatched variable name between the two would pass every other
# check in this file.
CAPTURE_FILE="$SCRATCH_DIR/captured-url"
cat > "$RESOURCE_DIR/capturing-open" <<EOF
#!/bin/sh
printf '%s' "\$1" > "$CAPTURE_FILE"
EOF
chmod +x "$RESOURCE_DIR/capturing-open"
env -i \
  HOME="$FAKE_HOME" \
  ZDOTDIR="$RESOURCE_DIR/zsh" \
  MYTERM_RESOURCE_DIR="$RESOURCE_DIR" \
  MYTERM_OPEN_SHIM="$RESOURCE_DIR/capturing-open" \
  PATH="/usr/bin:/bin" \
  zsh -lic 'open https://example.com/wired' </dev/null >/dev/null 2>&1
captured="$(cat "$CAPTURE_FILE" 2>/dev/null || true)"
if [ "$captured" != "https://example.com/wired" ]; then
  printf 'FAIL: open did not reach MYTERM_OPEN_SHIM; captured "%s"\n' "$captured" >&2
  exit 1
fi

# A bundle path can carry a space and zsh pattern characters. macOS produces
# exactly that on its own when the same disk image is downloaded twice
# (/Applications/myterm (1).app), so the PATH rebuild has to survive it.
AWKWARD_DIR="$SCRATCH_DIR/My Resources (1)"
mkdir -p "$AWKWARD_DIR"
cp -R "$ROOT_DIR/Resources/zsh" "$AWKWARD_DIR/zsh"
cp "$ROOT_DIR/Resources/open" "$AWKWARD_DIR/open"
chmod +x "$AWKWARD_DIR/open"
awkward_output="$(
  env -i \
    HOME="$FAKE_HOME" \
    ZDOTDIR="$AWKWARD_DIR/zsh" \
    MYTERM_RESOURCE_DIR="$AWKWARD_DIR" \
    MYTERM_OPEN_SHIM="$AWKWARD_DIR/open" \
    PATH="/usr/bin:/bin" \
    zsh -lic 'unfunction open; command -v open; c=0; for e in $path; do [ "$e" = "$MYTERM_RESOURCE_DIR" ] && c=$((c+1)); done; printf "COUNT:%s\n" "$c"' </dev/null 2>&1
)"
assert_contains "$AWKWARD_DIR/open" "$awkward_output" \
  "a resource directory containing a space and parentheses must still win the PATH lookup"
assert_contains "COUNT:1" "$awkward_output" \
  "the resource directory must appear in PATH exactly once, even when its name contains pattern characters"

# A user may set SH_WORD_SPLIT in their own .zshrc. Under that option an
# unquoted array expansion word-splits on whitespace, so the PATH rebuild has
# to quote both array expansions or it corrupts a pre-existing entry that
# contains a space rather than just reordering it. The measurement has to
# quote too - an unquoted `print -l -- $path` word-splits the printed values
# regardless of what the code under test did, which makes a correct fix look
# broken and a broken original look broken for the wrong reason.
SH_WORD_SPLIT_HOME="$SCRATCH_DIR/sh-word-split-home"
mkdir -p "$SH_WORD_SPLIT_HOME"
cat > "$SH_WORD_SPLIT_HOME/.zshrc" <<'EOF'
setopt SH_WORD_SPLIT
EOF
sh_word_split_output="$(
  env -i \
    HOME="$SH_WORD_SPLIT_HOME" \
    ZDOTDIR="$RESOURCE_DIR/zsh" \
    MYTERM_RESOURCE_DIR="$RESOURCE_DIR" \
    PATH="/some dir/with space:/usr/bin:/bin" \
    zsh -ic 'print -l -- "${(@)path}"; printf "COUNT:%s\n" "${#path}"' </dev/null 2>&1
)"
assert_contains "/some dir/with space" "$sh_word_split_output" \
  "a pre-existing PATH entry containing a space must survive the rebuild whole under SH_WORD_SPLIT"
assert_contains "COUNT:4" "$sh_word_split_output" \
  "the rebuild must not change the PATH entry count under SH_WORD_SPLIT (resource dir + 3 original entries)"

# A user's own .zshenv commonly relocates their dotfiles with
# `export ZDOTDIR="${ZDOTDIR:-$HOME/.config/zsh}"`. Plain zsh leaves ZDOTDIR
# unset until that line runs, so the default fires. The shim must not hand the
# user's file a ZDOTDIR of its own making: set to HOME it reads as "already
# chosen", the default never fires, and the dotfiles under .config/zsh are
# silently replaced by whatever sits in HOME.
RELOCATING_HOME="$SCRATCH_DIR/relocating-home"
mkdir -p "$RELOCATING_HOME/.config/zsh"
cat > "$RELOCATING_HOME/.zshenv" <<EOF
echo "zshenv-saw-ZDOTDIR=\${ZDOTDIR-unset}" >> "$MARKER_FILE"
export ZDOTDIR="\${ZDOTDIR:-\$HOME/.config/zsh}"
EOF
cat > "$RELOCATING_HOME/.config/zsh/.zshrc" <<EOF
echo "relocated-zshrc-ran" >> "$MARKER_FILE"
EOF
cat > "$RELOCATING_HOME/.zshrc" <<EOF
echo "home-zshrc-ran" >> "$MARKER_FILE"
EOF
: > "$MARKER_FILE"
relocating_output="$(
  env -i \
    HOME="$RELOCATING_HOME" \
    ZDOTDIR="$RESOURCE_DIR/zsh" \
    MYTERM_RESOURCE_DIR="$RESOURCE_DIR" \
    MYTERM_OPEN_SHIM="$RESOURCE_DIR/open" \
    PATH="/usr/bin:/bin" \
    zsh -lic 'printf %s "$MYTERM_ORIGINAL_ZDOTDIR"; type open' </dev/null 2>&1
)"
markers="$(cat "$MARKER_FILE")"
assert_contains "zshenv-saw-ZDOTDIR=unset" "$markers" \
  "a user with no ZDOTDIR of their own must see it unset in .zshenv, as plain zsh leaves it"
assert_contains "relocated-zshrc-ran" "$markers" \
  "the .zshrc under the ZDOTDIR chosen by the user's .zshenv default must run"
assert_not_contains "home-zshrc-ran" "$markers" \
  "once .zshenv relocates ZDOTDIR, the .zshrc left behind in HOME must not run"
assert_contains "$RELOCATING_HOME/.config/zsh" "$relocating_output" \
  "MYTERM_ORIGINAL_ZDOTDIR must follow the ZDOTDIR the user's .zshenv chose"
assert_contains "shell function" "$relocating_output" \
  "open must still be the shim function after the user's .zshenv relocates ZDOTDIR"

# The same relocation written unconditionally, which is the other common form.
cat > "$RELOCATING_HOME/.zshenv" <<EOF
export ZDOTDIR="\$HOME/.config/zsh"
EOF
: > "$MARKER_FILE"
env -i \
  HOME="$RELOCATING_HOME" \
  ZDOTDIR="$RESOURCE_DIR/zsh" \
  MYTERM_RESOURCE_DIR="$RESOURCE_DIR" \
  MYTERM_OPEN_SHIM="$RESOURCE_DIR/open" \
  PATH="/usr/bin:/bin" \
  zsh -ic 'true' </dev/null >/dev/null 2>&1
markers="$(cat "$MARKER_FILE")"
assert_contains "relocated-zshrc-ran" "$markers" \
  "an unconditional ZDOTDIR export in .zshenv must relocate the rest of the chain"
assert_not_contains "home-zshrc-ran" "$markers" \
  "an unconditional ZDOTDIR export in .zshenv must not also run the .zshrc in HOME"

# A user who already had ZDOTDIR in their environment reaches the shim with
# MyTermBrowserLauncher having carried it into MYTERM_ORIGINAL_ZDOTDIR. Every
# one of their startup files has to run from that directory, in zsh's own
# order, and a non-login shell must skip the login-only ones just as zsh does.
USER_ZDOTDIR="$SCRATCH_DIR/user-zdotdir"
USER_ZDOTDIR_HOME="$SCRATCH_DIR/user-zdotdir-home"
mkdir -p "$USER_ZDOTDIR" "$USER_ZDOTDIR_HOME"
for dotfile in .zshenv .zprofile .zshrc .zlogin .zlogout; do
  printf 'echo "user-zdotdir%s-ran" >> "%s"\n' "$dotfile" "$MARKER_FILE" > "$USER_ZDOTDIR/$dotfile"
  printf 'echo "home%s-ran" >> "%s"\n' "$dotfile" "$MARKER_FILE" > "$USER_ZDOTDIR_HOME/$dotfile"
done
run_user_zdotdir_zsh() {
  env -i \
    HOME="$USER_ZDOTDIR_HOME" \
    ZDOTDIR="$RESOURCE_DIR/zsh" \
    MYTERM_ORIGINAL_ZDOTDIR="$USER_ZDOTDIR" \
    MYTERM_RESOURCE_DIR="$RESOURCE_DIR" \
    MYTERM_OPEN_SHIM="$RESOURCE_DIR/open" \
    PATH="/usr/bin:/bin" \
    zsh "$@" </dev/null
}
: > "$MARKER_FILE"
run_user_zdotdir_zsh -lic 'true' >/dev/null 2>&1
markers="$(cat "$MARKER_FILE")"
expected_login_order="$(printf 'user-zdotdir%s-ran\n' .zshenv .zprofile .zshrc .zlogin .zlogout)"
if [ "$markers" != "$expected_login_order" ]; then
  printf 'FAIL: a login shell with a user ZDOTDIR must run exactly its five files in order\nexpected:\n%s\ngot:\n%s\n' \
    "$expected_login_order" "$markers" >&2
  exit 1
fi

: > "$MARKER_FILE"
run_user_zdotdir_zsh -ic 'true' >/dev/null 2>&1
markers="$(cat "$MARKER_FILE")"
expected_interactive_order="$(printf 'user-zdotdir%s-ran\n' .zshenv .zshrc)"
if [ "$markers" != "$expected_interactive_order" ]; then
  printf 'FAIL: a non-login shell with a user ZDOTDIR must run only .zshenv and .zshrc\nexpected:\n%s\ngot:\n%s\n' \
    "$expected_interactive_order" "$markers" >&2
  exit 1
fi

: > "$MARKER_FILE"
run_user_zdotdir_zsh -c 'true' >/dev/null 2>&1
markers="$(cat "$MARKER_FILE")"
if [ "$markers" != "user-zdotdir.zshenv-ran" ]; then
  printf 'FAIL: zsh -c with a user ZDOTDIR must run only .zshenv\ngot:\n%s\n' "$markers" >&2
  exit 1
fi

# MyTerm launched from a pane of another MyTerm installed as a different
# bundle. The child's launcher carries the parent's resolved
# MYTERM_ORIGINAL_ZDOTDIR forward and points ZDOTDIR at its own shim directory,
# while PATH still holds the parent's resource directory. The user's files must
# run exactly once, through the child's shim, and open has to resolve to the
# child's copy.
OTHER_RESOURCE_DIR="$SCRATCH_DIR/other-resources"
mkdir -p "$OTHER_RESOURCE_DIR"
cp -R "$ROOT_DIR/Resources/zsh" "$OTHER_RESOURCE_DIR/zsh"
cp "$ROOT_DIR/Resources/open" "$OTHER_RESOURCE_DIR/open"
chmod +x "$OTHER_RESOURCE_DIR/open"
: > "$MARKER_FILE"
nested_output="$(
  env -i \
    HOME="$USER_ZDOTDIR_HOME" \
    ZDOTDIR="$OTHER_RESOURCE_DIR/zsh" \
    MYTERM_ORIGINAL_ZDOTDIR="$USER_ZDOTDIR" \
    MYTERM_RESOURCE_DIR="$OTHER_RESOURCE_DIR" \
    MYTERM_OPEN_SHIM="$OTHER_RESOURCE_DIR/open" \
    PATH="$OTHER_RESOURCE_DIR:$RESOURCE_DIR:/usr/bin:/bin" \
    zsh -lic 'type open; unfunction open; command -v open; printf "ORIG=%s\n" "$MYTERM_ORIGINAL_ZDOTDIR"' </dev/null 2>&1
)"
markers="$(cat "$MARKER_FILE")"
if [ "$markers" != "$expected_login_order" ]; then
  printf 'FAIL: a nested MyTerm must run the user files exactly once through its own shim\nexpected:\n%s\ngot:\n%s\n' \
    "$expected_login_order" "$markers" >&2
  exit 1
fi
assert_contains "$OTHER_RESOURCE_DIR/zsh/.zshenv" "$nested_output" \
  "in a nested MyTerm the open function must come from the child's own shim"
assert_contains "$OTHER_RESOURCE_DIR/open" "$nested_output" \
  "in a nested MyTerm 'command -v open' must resolve to the child's resource directory"
assert_contains "ORIG=$USER_ZDOTDIR" "$nested_output" \
  "a nested MyTerm must keep the user's real ZDOTDIR in MYTERM_ORIGINAL_ZDOTDIR"
assert_not_contains "recursion" "$nested_output" \
  "a nested MyTerm must not trip zsh's recursion limiter"

# The same nesting from a parent pane whose shell is not zsh. That pane never
# ran the parent's shims, so it carries no MYTERM_ORIGINAL_ZDOTDIR, and the
# child's launcher falls back to the parent's shim directory as the "user's"
# ZDOTDIR. The child must recognise another copy's shim directory for what it
# is and go to HOME, not run the user's files through the other copy's shims.
# The parent copy here is instrumented so the test can tell whose shim ran.
printf 'echo "parent-shim-zshenv-ran" >> "%s"\n' "$MARKER_FILE" >> "$OTHER_RESOURCE_DIR/zsh/.zshenv"
: > "$MARKER_FILE"
foreign_shim_output="$(
  env -i \
    HOME="$USER_ZDOTDIR_HOME" \
    ZDOTDIR="$RESOURCE_DIR/zsh" \
    MYTERM_ORIGINAL_ZDOTDIR="$OTHER_RESOURCE_DIR/zsh" \
    MYTERM_RESOURCE_DIR="$RESOURCE_DIR" \
    MYTERM_OPEN_SHIM="$RESOURCE_DIR/open" \
    PATH="$RESOURCE_DIR:$OTHER_RESOURCE_DIR:/usr/bin:/bin" \
    zsh -lic 'type open; printf "ORIG=%s\n" "$MYTERM_ORIGINAL_ZDOTDIR"' </dev/null 2>&1
)"
markers="$(cat "$MARKER_FILE")"
expected_home_order="$(printf 'home%s-ran\n' .zshenv .zprofile .zshrc .zlogin .zlogout)"
if [ "$markers" != "$expected_home_order" ]; then
  printf 'FAIL: another copy'"'"'s shim directory handed in as the original ZDOTDIR must fall back to HOME, once per file\nexpected:\n%s\ngot:\n%s\n' \
    "$expected_home_order" "$markers" >&2
  exit 1
fi
assert_contains "$RESOURCE_DIR/zsh/.zshenv" "$foreign_shim_output" \
  "open must come from this copy's shim, not the other copy's"
assert_contains "ORIG=$USER_ZDOTDIR_HOME" "$foreign_shim_output" \
  "MYTERM_ORIGINAL_ZDOTDIR must end up as HOME, not the other copy's shim directory"

printf 'zsh shim checks passed\n'
