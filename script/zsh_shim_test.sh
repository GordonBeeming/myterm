#!/usr/bin/env bash
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

printf 'zsh shim checks passed\n'
