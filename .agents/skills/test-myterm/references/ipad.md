# iPad

Use the same existing iOS debugger/Simulator skills and GUI authorization gate as [iPhone](iphone.md). Read that reference's signed live-Simulator and authentication setup when pairing an iPad Simulator; the entitlement and process-environment boundaries are identical. This reference adds the tablet-specific checks rather than duplicating setup.

Run tablet fixtures separately from the phone:

```sh
COMPANION_DEVICE_FAMILY=iPad bash script/test_companion.sh
```

Choose a tablet destination with enough width for the adaptive layout. Preserve its result bundle and name the runtime/model in the report. Phone screenshots or a resized desktop window do not prove iPad layout.

For `LiveDeviceLayoutTests`, set `MYTERM_LIVE_IPAD_TEST=1`, `MYTERM_LIVE_HOST_NAME` and `MYTERM_LIVE_WORKSPACE` on the UI runner. Prepare that disposable development workspace with the four real terminal panes the test expects. The layout suite must enter **Workspaces** view, not the session inbox: it launches with `-showsSessionInbox NO` so it can select the prepared workspace. Inbox navigation/create/regression checks instead deliberately launch with `-showsSessionInbox YES`; those are different entry paths to test, not interchangeable flags. The Mac's corresponding workspace, groups and terminals must remain available. No fixture launch flags, canned projections or recreated local terminals qualify as this live setup.

Verify in landscape that the real panes mirror their identities and split proportions, controls remain reachable, and the compact pane switcher is absent where all panes fit. Check portrait/narrow window behavior separately: keyboard presentation, pane selection and changing focus must preserve the destination and reading position. Restore orientation after the check. If Stage Manager, external keyboard or multitasking behavior is requested, test the actual available configuration and report unsupported hardware rather than simulating a result.

Run [workflow checks](workflows.md) for shared features. Pay particular attention to inbox → workspace detail → inbox → same-session selection and automatic opening after workspace creation. Verify both normal sidebar selection and inbox entry selection, with no duplicated navigation stack. Saved prompts must come from the same Mac catalog visible on the desktop, not a local duplicate.

A Simulator can prove adaptive layout and live relay behavior on the test network. It cannot prove cellular handoff, physical touch ergonomics, hardware keyboard handling or APNs delivery on a real iPad. Physical iPad setup uses the normal signing/passkey path in `docs/COMPANION.md` and requires its own GUI/device authorization.
