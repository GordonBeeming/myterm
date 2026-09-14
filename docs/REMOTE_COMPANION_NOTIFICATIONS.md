# Telling the phone an agent needs you

How MyTerm Remote can tell the person, on an iPhone or an iPad, that an agent on the Mac finished
or asked a question, the way the Mac's own banner does. This is the plan behind the "Later: push
notification" line in `REMOTE_COMPANION.md`, written after looking at what iOS actually allows.

## What works today

- The Mac keeps `agentAttention` per tab and an `AgentNotificationInbox` of tabs waiting for the
  user. Every change to a tab's state is pushed to every connected device as an `agentActivity`
  control message carrying the tab identifier and the state the Mac is showing, which is `nil`
  once the Mac has read the tab. The once-a-second tree poll carries the same state, so a device
  that reconnects sees the current dots without any event replay.
- The device patches that into its copy of the tree, and the tree draws the cook beside the tab
  and the workspace, exactly as the Mac's sidebar does.
- The Mac itself posts a macOS notification through `UserNotificationPoster` when the agent
  reports and MyTerm is not the active app, and clicking it brings the tab forward.

What a device gets when it is not in front:

- **Backgrounded, first seconds.** iOS gives an app about five seconds after it leaves the
  screen, then suspends it. Nothing in the app asks for more, so today the socket is effectively
  dead five seconds after the person switches away. A suspended app runs no code: bytes the Mac
  sends sit unread, and iOS commonly tears the socket down before the app returns.
- **Backgrounded longer, or closed.** Nothing. The app only learns what happened when it returns
  to the foreground and reconnects, which `ConnectionView` already does on `scenePhase == .active`.
  The dots are then right, because the tree carries the state, but nobody was told in between.
- **Foreground, on another screen.** The dot updates live, but a person reading a different tab's
  conversation, or the workspace list, gets no banner and no sound. On an iPad with the app in one
  Stage Manager window and Safari in front, the same: the app is foreground, connected, and silent.

## Option A: local notifications from the app

Post a `UNUserNotificationCenter` notification from the app itself when an `agentActivity` message
says a tab needs attention and that tab is not on the screen in front of the person.

What iOS lets a backgrounded app do:

- `UNUserNotificationCenter.add` works whenever the process is running, foreground or background.
  A banner for the foreground case is shown only if the app's notification delegate says so in
  `willPresent`, which is the hook that makes "you are in the app but on the wrong tab" work.
- Leaving the screen starts a countdown to suspension. `UIApplication.beginBackgroundTask`
  extends it from about five seconds to about thirty (`backgroundTimeRemaining` reports roughly
  30 s on current iOS, and the system can shorten it). During that window the socket is alive and
  the delegate runs, so an agent that finishes within half a minute of the person putting the phone
  down still produces a banner. After the window, the app is suspended and nothing runs.
- There is no background mode that keeps a plain TCP socket alive for a terminal app. `voip`
  needs PushKit and CallKit and is an App Review rejection when used for anything else; `audio`
  needs audio actually playing; `fetch` (BGAppRefreshTask) runs when the system chooses, minutes to
  hours later, and is not a way to deliver a timely alert; `remote-notification` is APNs, which is
  Option B.

What Option A covers: the app in the foreground on any other screen, the iPad case where the app
stays foreground beside other windows, and the first thirty seconds after backgrounding.

What it cannot cover: a locked phone in a pocket, and an app that has been in the background for
more than the grace window. Those are the cases most people picture when they say "notify my
phone", and no amount of local code reaches them. Say so in the interface rather than let the
person discover it.

Cost: small. A pure decision type, a thin wrapper over `UNUserNotificationCenter`, an app
delegate to own the notification delegate from launch so a tap on a cold app still opens the tab,
one settings toggle, and the background task. No new infrastructure, no secrets, no protocol change.

## Option B: real push through the relay

Only Apple Push Notification service wakes an app that is suspended or not running. Everything
below follows from that.

What is needed:

1. **A paid Apple Developer Program membership.** The `aps-environment` entitlement is not
   available to free provisioning, and the companion doc currently says a free Apple ID is enough to
   build the app to a device. Push changes that for anyone who builds their own copy.
2. **An APNs authentication key** (`.p8`, with its key ID and the team ID) created in the
   developer account. One key serves every app on the team and does not expire, so it is the right
   shape for a service. A certificate would also work and expires yearly; do not choose it.
3. **The relay sends the push.** The Cloudflare Worker holds the `.p8` as a secret, mints an ES256
   JWT, and POSTs to `api.push.apple.com/3/device/<token>` with the app's bundle identifier as the
   topic. APNs speaks HTTP/2 only. Workers `fetch` normally reaches origins over HTTP/2, but this has
   to be proven with a spike before anything is designed on top of it; if it does not hold, a small
   sender outside Workers is needed. The key must live in the relay, never on a user's Mac: it is
   the private key for every user's pushes, and a Mac is not a place to keep it.
4. **Device token registration over the existing protocol.** The app receives its token in
   `didRegisterForRemoteNotificationsWithDeviceToken` and sends it to the Mac in a new device-to-host
   control message, inside the TLS session. The Mac then registers the token with the relay over the
   control socket it already holds, keyed by rendezvous identifier. The relay's data model grows one
   list of tokens per rendezvous, with a way to drop one when a device is revoked or the token
   changes. That is the relay change this task does not make.
5. **A "notify" message from the Mac to the relay** when `recordAgentActivity` files an inbox entry
   and no device is connected to receive `agentActivity` directly. A device that is connected does
   not need a push; Option A handles it.

Privacy, given the relay must never read terminal content, tab titles, or workspace names:

- The push payload the relay builds carries **no title and no workspace name**. A fixed alert, "An
  agent needs you", plus the rendezvous identifier it already knows. The relay learns that a push
  happened, which is no more than it already learns from the traffic. The app opens, reconnects,
  and the tree tells it what.
- If a named banner matters later, the Mac encrypts the title with a key both ends hold from
  pairing and puts the ciphertext in the payload with `mutable-content: 1`. A Notification Service
  Extension decrypts it on the device before the banner shows. That costs an extension target, a
  keychain access group so the extension can read the pairing key, and a second code-signing
  identity. It is the right second step, not the first.
- A push carries the tab identifier only inside that ciphertext or not at all. The plain first
  version sends nothing a device can act on other than "open the app".
- The Mac's inbox already answers "which tabs need me", so the app after waking has the detail it
  needs without the push carrying it.

Cost: the largest piece of work on the companion app since the relay itself. A developer account
change, a secret to hold and rotate, a relay data model change, a new control message on both ends,
APNs error handling (410 for a dead token, rate limits), and the iOS side for tokens and taps. Two
to three weeks of focused work with the spike, plus the operational obligation of holding an APNs
key for a service that other people's devices trust.

## Option C: anything cheaper

- **Silent pushes** (`content-available: 1`) do not help. They are throttled, deferred when the
  system feels like it, and never delivered after the person force-quits the app. They also need
  the same APNs key. They could refresh the tree in the background one day, but they are not an
  alert path.
- **Live Activities** cannot start or update without the app running or an APNs push. On iOS 17.2
  and later a push can start one, so a lock-screen "2 agents waiting" activity is a good display
  layer on top of Option B. It is not a way around it.
- **The Mac's own notification, mirrored.** macOS has no notification mirroring toward iOS. iPhone
  Mirroring goes the other way. Not an option.
- **A third-party push relay** (ntfy, Pushover, a Shortcuts automation). A person can wire the
  Mac's agent hooks to one themselves today; it is not something to ship, because the titles leave
  the Mac in the clear, or the person has to run a server.
- **Keeping the app in front.** An iPad on a stand with auto-lock off, or the app in a Stage
  Manager window, keeps the socket alive indefinitely. Option A serves exactly this. It is not a
  general answer, but it is the honest description of the best case.

## Recommendation

Ship Option A now. It is cheap, it needs nothing outside the repository, and every piece of it is
also needed by Option B: the permission request, the decision of whether to post, the tap that opens
the tab, the toggle. Its limits are real and are stated in the app beside the toggle.

Plan Option B as the contentless push described above, in this order: prove the Worker can reach
APNs, confirm the developer account, add the token message and the relay's token list, send the
fixed-text push when no device is connected. Named banners through a service extension come after.

The smallest first step that gives value is Option A with the thirty-second background grace: the
person who puts the phone down as the agent is about to finish still gets told, the person on the
wrong tab gets told, and the iPad beside a Mac gets told.

## What Option A does, as built

- `RemoteAgentNotificationPolicy` in `MyTermRemoteProtocol` decides, from one `agentActivity`
  message and the tree, whether to post a banner, take one down, or do nothing. It is pure and
  tested: post only when the state changed to one needing attention and the tab is not in front of
  the person; withdraw when the Mac read the tab, the agent moved on, or the tab is on screen.
- `AgentNotifier` in the app wraps `UNUserNotificationCenter`: it posts with the tab identifier as
  the request identifier so a tab holds one banner, withdraws by the same identifier, shows banners
  in the foreground, and answers a tap by writing `remote.openTab`, which `ConnectionView` already
  turns into opening the tab in whichever layout is on screen.
- Opening a tab on the device withdraws its banner. The Mac reading the tab withdraws it too,
  because that arrives as `agentActivity` with no state.
- The toggle lives on the list of Macs beside "Reconnect on launch", off until asked for, as it is
  on the Mac. Turning it on is what asks iOS for permission.
- `ConnectionView` holds a background task while the connection is up, so the socket lives about
  thirty seconds after the app leaves the screen instead of five.
