# Account move protocol prototype

Open `candidate.html` directly for the interactive state model and proposed protocol. It is a throwaway decision artifact. No production app, relay, credentials or terminal processes are modified.

Run the bounded protocol checks with Node:

```sh
node script/relay-move-prototype/checks.cjs /private/tmp/myterm-move-results.json
```

The harness extracts the same reducer used by the page. It checks the proposed state transitions, then uses Node's Ed25519 implementation to sign and verify ticket, endpoint-approval, prepared-transfer and location-commit and activation/discovery fixtures. It records source hashes and environment alongside named checks. The passkey and transfer-key values are fixtures; this does not test WebAuthn, HPKE, private-state transfer, production membership or network/disk recovery. See the candidate's validation limits before interpreting a passing run.

Gordon accepted requiring the existing ordering server for unavailable-source moves and an empty destination account. Gordon also accepted the explicit source-passkey override with one approved endpoint, the existing ordering server and destination passkey sign-in; no second device is required. Gordon accepted missing-content fallback after explicit acknowledgement of possible irrecoverable newer changes, including gaps that cannot be enumerated. Missing security state must fail closed regardless of the content-loss decision. The prototype direction is selected; production validation remains open.

Sources: [account operations policy](https://github.com/GordonBeeming/myterm/issues/134), [accepted trust protocol direction](https://github.com/GordonBeeming/myterm/issues/141), [move validation question](https://github.com/GordonBeeming/myterm/issues/143), [Node crypto API](https://nodejs.org/api/crypto.html).

The current bounded run passes 82/82 checks on macOS ARM64 with Node v24.14.0. Retained evidence records the exact source and harness hashes. Ten guided scenarios are checked at 1920- and 800-pixel widths. The independent review reports distinguish source defects from open human decisions.

For headless visual checks, with Playwright and Chromium already installed:

```sh
node script/relay-move-prototype/visual-qa.cjs script/relay-move-prototype/candidate.html /private/tmp/myterm-move-qa
```

The runner checks each walkthrough at both viewport widths, script errors, text encoding, horizontal overflow and an explicit list of text/surface contrast pairs used by the page. Inspect the screenshots before deleting them. It does not replace native-app UI validation.

Claude ran the 49-check, 66-check and 80-check revisions and found no material blocker to selecting the bounded prototype direction in its final read. Its reports are retained under `evidence/`. Two final low-severity reducer findings were corrected afterward: re-staging now retains the source fence, and a security-state change also invalidates content-loss acknowledgement. The final 82-check run adds regressions for both; those last fixes have not had a further independent read. This is model review, not approval of production security.
