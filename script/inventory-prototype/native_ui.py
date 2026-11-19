"""Drive only the disposable prototype, using Gordon-authorized AppleScript."""
import json
from pathlib import Path
import subprocess
import time

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / 'evidence'


def apple(script, *args):
    result = subprocess.run(['osascript', '-', *map(str, args)], input=script, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def snapshot():
    return apple('''tell application "System Events" to tell application process "InventoryPrototype"
        set textParts to {}
        set parts to entire contents of window 1
        repeat with part in parts
            try
                if role of part is "AXStaticText" then set end of textParts to value of part
            end try
        end repeat
        set AppleScript's text item delimiters to linefeed
        return textParts as text
    end tell''')


def wait_for(text):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = snapshot()
        if text in result:
            return result
    raise AssertionError(f'Native UI did not show {text!r}')


def capture(name):
    # Read actual window geometry. The capture contains only the disposable window.
    geometry = apple('''tell application "System Events" to tell application process "InventoryPrototype"
        return (position of window 1) & (size of window 1)
    end tell''')
    rect = ','.join(part.strip() for part in geometry.split(','))
    subprocess.run(['screencapture', '-x', '-R' + rect, str(EVIDENCE / name)], check=True)


def run():
    apple('tell application "System Events" to tell application process "InventoryPrototype" to key code 53')
    frames = json.loads((EVIDENCE / 'walkthroughs.json').read_text())
    results = []
    for index, scenario in enumerate(frames):
        apple('tell application "System Events" to tell application process "InventoryPrototype" to click pop up button 1 of group 1 of window 1')
        apple('''on run argv
            tell application "System Events" to tell application process "InventoryPrototype"
                set frontmost to true
                click menu item (item 1 of argv) of menu 1 of pop up button 1 of group 1 of window 1
            end tell
        end run''', scenario['name'])
        apple('tell application "System Events" to tell application process "InventoryPrototype" to click button 1 of group 1 of window 1')
        count = len(scenario['frames']) - 1
        wait_for(f'Step 0 of {count}')
        if index == 0:
            capture('native-before.png')
        for step, frame in enumerate(scenario['frames'][1:], start=1):
            apple('tell application "System Events" to tell application process "InventoryPrototype" to click button 2 of group 1 of window 1')
            observed = wait_for(f'Step {step} of {count}')
            assert frame['label'] in observed, (scenario['name'], step, observed)
            assert 'Control: None' in observed, (scenario['name'], step)
            assert f"Selected tab: {frame['selected']}" in observed, (scenario['name'], step)
            assert f"Existing layout target: {frame['selectedWorkspace']} / {frame['selectedPane']} / {frame['selectedTab']}" in observed, (scenario['name'], step)
            if scenario['name'] == 'Find existing work' and step == 6:
                assert 'Focus: browser' in observed and 'tab-web' in observed
            if scenario['name'] == 'Read an older turn' and step in [3, 4, 5, 6]:
                capture(f'native-attention-{step}.png')
                if step == 4:
                    assert 'Needs attention' not in observed and 'Finished' in observed
                if step in [5, 6]:
                    assert 'Needs attention' in observed
            if scenario['name'] == 'Two input requests' and step in [4, 5, 6]:
                assert 'Waiting for input' in observed and 'Needs attention' in observed
            if scenario['name'] == 'Quiet and disconnected' and step in [3, 4, 5]:
                assert 'Stale' in observed
            if scenario['name'] == 'Returning stale client' and step >= 4:
                assert 'Content build ' not in observed
            results.append({'scenario': scenario['name'], 'step': step, 'label': frame['label'], 'result': 'pass', 'observed': observed})
        capture(f'native-scenario-{index + 1}.png')
    (EVIDENCE / 'native-ui.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'{len(results)} native scenario steps passed using AppleScript')


if __name__ == '__main__':
    run()
