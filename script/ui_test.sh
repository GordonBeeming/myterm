#!/bin/bash
# Runs the companion app's UI tests against a live host.
#
# The host is `RemoteHostDemo`, which serves three real shells from this package's tests, so the
# device under test types into a process and sees its screen the way it would against MyTerm.
#
#   script/ui_test.sh                       # iPhone, screenshots into ./dist/ui-shots
#   script/ui_test.sh "iPad Pro 13-inch (M5)"
#   MYTERM_SHOTS_DIR=/tmp/shots script/ui_test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

simulator="${1:-iPhone 17 Pro}"
shots="${MYTERM_SHOTS_DIR:-$PWD/dist/ui-shots}"
derived="${MYTERM_DERIVED_DATA:-$PWD/.build/ui-derived}"
work="$(mktemp -d)"
url_file="$work/demo_url.txt"
control_file="$work/demo_control.txt"
mkdir -p "$shots"

# The agent tests read transcripts. The host finds a session by identifier alone, anywhere under
# ~/.claude/projects, so the fixtures are staged there in a directory of their own for the run
# and removed afterwards. The first is the conversation the demo's agent tab opens on; the second
# is what a /clear would start; the third ends on a pipe table.
fixtures="$PWD/apps/MyTermRemote/Tests/MyTermRemoteUITests/Fixtures/agent-projects"
agent_projects="$HOME/.claude/projects/myterm-remote-ui-test-fixtures"
agent_session="11111111-1111-4111-8111-111111111111"
agent_next_session="22222222-2222-4222-8222-222222222222"
agent_table_session="33333333-3333-4333-8333-333333333333"
mkdir -p "$agent_projects"
cp "$fixtures"/*/*.jsonl "$agent_projects/"

# With the relay's dependencies installed, a local Worker runs too, and the host registers with
# it, so the relay flow is tested as well. `cd relay && npm install` turns this on.
relay_url=""
if [ -x relay/node_modules/.bin/wrangler ]; then
    relay_port=8798
    (cd relay && CI=1 node_modules/.bin/wrangler dev --port "$relay_port" --local --log-level error >"$work/relay.log" 2>&1) &
    relay_pid=$!
    for _ in $(seq 1 120); do
        curl -sf "http://127.0.0.1:$relay_port/v1/health" >/dev/null 2>&1 && break
        sleep 1
    done
    if curl -sf "http://127.0.0.1:$relay_port/v1/health" >/dev/null 2>&1; then
        relay_url="http://127.0.0.1:$relay_port"
        echo "relay ready on port $relay_port"
    else
        echo "the local relay did not come up; the relay flow will be skipped" >&2
    fi
fi

# Serve terminals for as long as the tests could take, then let the host exit on its own.
MYTERM_REMOTE_DEMO=1 \
MYTERM_REMOTE_DEMO_RELAY="$relay_url" \
MYTERM_REMOTE_DEMO_SECONDS="${MYTERM_REMOTE_DEMO_SECONDS:-900}" \
MYTERM_REMOTE_DEMO_URL_FILE="$url_file" \
MYTERM_REMOTE_DEMO_CONTROL_FILE="$control_file" \
MYTERM_REMOTE_DEMO_AGENT_SESSION="$agent_session" \
swift test --scratch-path "$work/build" --filter RemoteHostDemo >"$work/demo.log" 2>&1 &
demo_pid=$!
trap 'kill "$demo_pid" 2>/dev/null || true; [ -n "${relay_pid:-}" ] && pkill -f "wrangler dev --port $relay_port --local" 2>/dev/null; rm -rf "$work" "$agent_projects"' EXIT

for _ in $(seq 1 300); do
    [ -f "$url_file" ] && break
    if ! kill -0 "$demo_pid" 2>/dev/null; then
        echo "the demo host exited before it was ready:" >&2
        tail -20 "$work/demo.log" >&2
        exit 1
    fi
    sleep 1
done
[ -f "$url_file" ] || { echo "the demo host never wrote its address" >&2; exit 1; }

url="$(cat "$url_file")"
host_name="$(sed -E 's/.*host=([^&]+).*/\1/' <<<"$url")"
port="$(sed -E 's/.*port=([0-9]+).*/\1/' <<<"$url")"
token="$(sed -E 's/.*token=([^&]+).*/\1/' <<<"$url")"
rendezvous="$(sed -nE 's/.*rendezvous=([^&]+).*/\1/p' <<<"$url")"
echo "host ready: $url"

# xcodebuild forwards TEST_RUNNER_-prefixed variables to the test bundle with the prefix removed.
TEST_RUNNER_MYTERM_REMOTE_HOST="$host_name" \
TEST_RUNNER_MYTERM_REMOTE_PORT="$port" \
TEST_RUNNER_MYTERM_REMOTE_RELAY="$relay_url" \
TEST_RUNNER_MYTERM_REMOTE_RENDEZVOUS="$rendezvous" \
TEST_RUNNER_MYTERM_REMOTE_TOKEN="$token" \
TEST_RUNNER_MYTERM_SHOTS_DIR="$shots" \
TEST_RUNNER_MYTERM_REMOTE_CONTROL_FILE="$control_file" \
TEST_RUNNER_MYTERM_REMOTE_AGENT_TAB="tab-1" \
TEST_RUNNER_MYTERM_REMOTE_AGENT_NEXT_SESSION="$agent_next_session" \
TEST_RUNNER_MYTERM_REMOTE_AGENT_TABLE_SESSION="$agent_table_session" \
xcodebuild test \
    -project apps/MyTermRemote/MyTermRemote.xcodeproj \
    -scheme MyTermRemote \
    -destination "platform=iOS Simulator,name=$simulator" \
    -derivedDataPath "$derived" \
    -resultBundlePath "$shots/results-$(date +%Y%m%d-%H%M%S).xcresult" \
    ${MYTERM_UI_TEST_FILTER:+-only-testing:"MyTermRemoteUITests/$MYTERM_UI_TEST_FILTER"} \
    2>&1 | grep -E "Test Case|error:|failed|passed|\*\* TEST" || true

echo "screenshots in $shots"
