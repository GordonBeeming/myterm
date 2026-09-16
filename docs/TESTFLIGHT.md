# MyTerm Companion TestFlight deployment

MyTerm Companion is archived, validated, and uploaded from the GitHub Actions `Companion` workflow. A release upload does not use a developer's login keychain or a locally exported archive.

## One-time Apple setup

Create the iOS app in App Store Connect before the first workflow run. App Store Connect does not provide an API for creating the app record, so this step must be completed in the App Store Connect website.

- App name: `MyTerm Companion`
- Primary bundle ID: `com.gordonbeeming.myterm.companion`
- Notification service bundle ID: `com.gordonbeeming.myterm.companion.notifications`

Create or download App Store distribution profiles for both bundle IDs. The app profile must include the capabilities declared by `MyTermCompanion.entitlements`; the notification profile must include the shared app and keychain groups declared by `MyTermNotificationService.entitlements`. Both profiles must use the Apple Distribution certificate supplied to GitHub.

Create an App Store Connect API key whose role permits build validation and upload. Keep the original `.p8` file: App Store Connect only offers it once.

For installation on personal devices, create an internal testing group in the app's **TestFlight** tab. Enable automatic distribution for the group, then invite the relevant App Store Connect users. If an Apple Account is not listed, first add it under **Users and Access** with a role eligible for internal testing. Each tester accepts the invitation and installs the build in Apple's TestFlight app. See Apple's [internal tester setup](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers).

## GitHub `beta` environment

Configure an environment named `beta` and restrict its deployment branch to `main`. Store these values in the environment rather than repository-level secrets so its protection rules apply to every upload.

Variables:

| Name | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `CODE_SIGN_IDENTITY` | Common name of the imported Apple Distribution identity |
| `PROVISIONING_PROFILE_NAME` | Exact `Name` from the app provisioning profile |
| `NOTIFICATION_PROVISIONING_PROFILE_NAME` | Exact `Name` from the notification service provisioning profile |
| `APP_STORE_CONNECT_API_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer UUID |
| `MYTERM_PUSH_GATEWAY_ORIGIN` | Optional HTTPS origin without credentials, a path, query, or fragment; leave empty until the gateway is deployed |

Secrets:

| Name | Format |
| --- | --- |
| `CERTIFICATES_P12` | Base64-encoded Apple Distribution `.p12` |
| `CERTIFICATES_PASSWORD` | Password used when exporting that `.p12` |
| `PROVISIONING_PROFILE` | Base64-encoded app `.mobileprovision` |
| `NOTIFICATION_PROVISIONING_PROFILE` | Base64-encoded notification service `.mobileprovision` |
| `APP_STORE_CONNECT_API_KEY` | Original App Store Connect `.p8` contents |

The two profile-name variables must exactly match the embedded `Name` values. The helper also verifies that each profile's application identifier matches its expected bundle ID before installing it.

## Deployment behavior

Relevant pull requests run the remote, relay, service, iPhone, and iPad test jobs without access to the `beta` environment. A relevant push to `main`, or a manual dispatch explicitly run from `main`, uploads only after all of those jobs pass.

The app and notification extension set `ITSAppUsesNonExemptEncryption: false` in `Companion/project.yml`. The declaration is included in each build so App Store Connect does not require the same encryption answer after every upload.

This records the OS-provided-encryption classification for both targets. Pairing, terminal messages, and notification content use Apple's CryptoKit `HPKE.Sender` and `HPKE.Recipient` with `P256_SHA256_AES_GCM_256`; signing, hashing, and key derivation also use CryptoKit. HTTPS uses the system networking implementation. These algorithms are supplied by Apple's operating system, with no separately bundled cryptographic implementation. The relevant code is in [PairingCrypto.swift](../Packages/MyTermRemote/Sources/MyTermRemote/PairingCrypto.swift), [AuthenticatedChannel.swift](../Packages/MyTermRemote/Sources/MyTermRemote/AuthenticatedChannel.swift), and [PushNotificationCrypto.swift](../Packages/MyTermRemote/Sources/MyTermRemote/PushNotificationCrypto.swift).

Apple's [encryption documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption) lists OS-provided encryption as requiring no App Store Connect documentation. Its [metadata guidance](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption) permits `false` for exempt encryption. Revisit the declaration if either target adopts bundled or proprietary cryptography.

The deploy job:

1. Selects release Xcode 26.6, verifies the iOS 26 SDK, and installs its matching Metal toolchain.
2. Imports the distribution certificate into a new runner-only keychain.
3. Installs the app and notification service profiles after validating their names and bundle IDs.
4. Generates an isolated Release project and archives both targets with manual signing.
5. Sets `CURRENT_PROJECT_VERSION` to `github.run_number`.
6. Exports the IPA, runs `altool --validate-app`, then runs `altool --upload-app`.
7. Uploads the exported IPA as a 90-day GitHub artifact, including when App Store validation or upload fails after export.
8. Removes the temporary key, certificate, profiles, and keychain on every exit path.

Both `altool` commands must succeed. The helper also treats known `altool` failure text as a job failure instead of allowing a misleading green run.

An upload success means Apple accepted the binary for processing. It does not mean the build is immediately installable: wait until processing completes in App Store Connect. Apple documents this separately in [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds). If a build shows **Missing Compliance**, check that its exported app contains the declaration documented above. Builds uploaded before this metadata was included may still require the matching answer in App Store Connect.

With automatic distribution enabled, a processed and compliance-ready build is delivered to the internal group. Without automatic distribution, select the group and add the build manually before it appears in TestFlight.

To request a deployment, open **Actions → Companion → Run workflow**, select `main`, and run it. A dispatch from another branch runs no deploy job.

## Local verification

Local verification renders and checks the signing configuration without importing credentials, archiving, or contacting App Store Connect:

```sh
bash script/test_companion_testflight_helper.sh
```

Do not invoke `deploy_companion_testflight.sh` locally with production credentials. The GitHub `beta` environment is the release boundary.
