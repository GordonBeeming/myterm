# Account trust and encrypted session protocols

Research for [Establish a protocol for account trust and encrypted sessions](https://github.com/GordonBeeming/myterm/issues/140), 7 November 2026 AEST. Requirements come from [Choose account trust and key ownership](https://github.com/GordonBeeming/myterm/issues/129). This report recommends a design investigation; it does not approve an architecture or establish the security of a new protocol. No implementation, interoperability testing or security audit was performed.

## Recommended next step

Investigate TLS 1.3 with mutual endpoint authentication, carried inside an opaque relay tunnel, as the first pairwise channel candidate. Keep account membership, admission and directory authorization explicit and independently verifiable. Retain HPKE as a candidate for delivering directory keys to authenticated recipients. Noise is a credible alternative if its framing and Apple integration costs prove preferable in a prototype.

No examined protocol supplies MyTerm's whole account-management policy. The next human decision should establish what trusted issuer must be available during unattended enrollment. That determines whether generic bearer invitations can be single-use against a malicious relay. Partitioned revocation and competing administrators then need explicit conflict rules before choosing a credential representation.

## Channel evidence

| Candidate | Established properties | Work still belonging to MyTerm |
| --- | --- | --- |
| TLS 1.3 | Authenticated key exchange, encrypted records and traffic-key updates. | Endpoint membership verification, relay stream adapter, reconnection and application authorization. |
| Noise | Named handshake patterns, static and ephemeral keys, encrypted transport messages. | Pattern choice, framing, credential binding, rekey signalling and reconnect policy. |
| Existing authenticated HPKE | Encryption to a recipient key with optional sender authentication. | A bidirectional channel protocol and recipient-side forward secrecy. |

TLS 1.3 with certificate authentication and fresh (EC)DHE provides forward secrecy. Require mutual authentication; disable 0-RTT for admission and terminal actions because it is replayable. KeyUpdate derives the next traffic secret from the existing one, so a stolen traffic secret reveals subsequent secrets on that connection. Recovering from that exposure requires a fresh connection with (EC)DHE. Compromise of the peer's identity signing key defeats subsequent authentication until trust is repaired. These limitations are explicit in [RFC 8446, sections 2, 4.6.3, 7.2, E.1.5 and E.2](https://www.rfc-editor.org/rfc/rfc8446.html#section-E.2).

For MyTerm, an inner TLS connection would terminate at the approved client and session server. Outer HTTPS/WebSocket termination at the relay can remain operational transport protection. The relay forwards inner ciphertext and can still withhold it or observe traffic metadata. A tunnel needs ordered, reliable byte delivery and backpressure; WebSocket message boundaries need not become TLS record boundaries. This is an architectural application of TLS, with feasibility supported by [rustls's transport-independent record I/O](https://docs.rs/rustls/latest/rustls/struct.ConnectionCommon.html). TLS certificates must authenticate the account-approved endpoint, including when connecting by IP, rather than accepting any publicly valid hostname certificate.

Noise IK assumes the initiator already knows the responder's static public key; XX exchanges static keys during the handshake, whose legitimacy the application must establish. An authenticated encrypted directory could provide that binding. The framework assigns applications framing, key acceptance and other policy. Its one-way `Rekey()` adds no fresh DH entropy; scheduling and signalling are application responsibilities. A new handshake is a separate operation. See [Noise sections 7, 11.3 and 13](https://noiseprotocol.org/noise.html#application-responsibilities). Noise therefore reduces some certificate machinery but does not remove account trust design.

HPKE explicitly lacks forward secrecy against compromise of its recipient's long-term key. Sender-authenticated mode does not change that. Replay protection is also an application responsibility. Repeatedly creating HPKE contexts addressed to the same durable recipient key cannot satisfy the requested session guarantee. HPKE remains useful for encrypting a directory-key envelope to an already authenticated device; recipient compromise can expose retained envelopes. See [RFC 9180, sections 9.7.3 and 9.7.4](https://www.rfc-editor.org/rfc/rfc9180.html#section-9.7.4).

Forward secrecy protects earlier traffic after later key exposure, subject to key deletion. Rekeying changes a traffic key. Post-compromise recovery needs new secret material unavailable to the attacker after compromise ends. A fresh authenticated DH handshake can restore confidentiality after traffic-state exposure if identity keys remain trustworthy; it does not repair stolen identity authority. Preserve terminal processes across channel replacement through the server's attachment protocol.

The [Double Ratchet specification](https://signal.org/docs/specifications/doubleratchet/#diffie-hellman-ratchet) explains how DH inputs provide recovery that symmetric chains lack. It adds persistent message state and still needs authenticated initialization. [MLS](https://www.rfc-editor.org/rfc/rfc9420.html#section-16.6) provides asynchronous group key establishment with FS/PCS, but assumes credential authentication and adds group-epoch synchronization. Its delivery service can suppress updates and defeat recovery. Neither is an automatic answer to account enrollment, revocation ordering or this release's pairwise terminal streams. Investigate them further only if continuous ratchet recovery or account-wide group encryption becomes a requirement.

## Account authority and unique device keys

The first client can create an account genesis record containing its public authority and pin it locally. Additional clients need that genuine account binding through an existing trusted endpoint. Passkey sign-in to the relay cannot independently establish it under the agreed malicious-relay threat model. This is a consequence of the requirements: an untrusted service supplying both an anchor and its evidence can substitute both.

Each endpoint should generate its own keys. Consider separate signing/authentication and directory-envelope key pairs with explicit purposes, authenticated together in its membership credential. These are candidate design choices; algorithms and key storage remain open. A common directory symmetric key is compatible with distinct private device identities, but possession of that symmetric key must not imply admission authority.

[RFC 5280](https://www.rfc-editor.org/rfc/rfc5280.html#section-3.3) supplies established certificate-chain, key-usage and revocation machinery. It makes issuers responsible for certificate revocation, optionally delegating CRL publication. CRL numbers are monotonic for a particular issuer and scope. It does not define MyTerm's rule that every admitted endpoint can revoke every other endpoint across concurrent offline histories. A tree of endpoint CAs also creates ancestor dependencies: removing an intermediate can invalidate its descendants. Simply making each device a CA therefore leaves product semantics unresolved.

A practical design study can compare X.509 credentials against signed account membership records while retaining the same TLS channel. Both need account binding, subject keys, permitted authority, admission evidence and revocation interpretation. The latter representation is application protocol work requiring review; standard signature primitives do not establish its correctness. Keep the account's stable public identity distinct from the question of whether its first client remains authorized, or revoking that client may accidentally require replacing everybody's anchor.

## Short-code approval through an untrusted relay

OAuth device flow has a useful familiar UX, but [RFC 8628 section 5](https://www.rfc-editor.org/rfc/rfc8628.html#section-5) relies on an authorization server, code entropy and rate limits. A compromised relay can bypass its own limits and substitute pending requests. Using its short code as the sole request lookup does not authenticate the endpoint Gordon intended to approve.

An established candidate for the cryptographic step is a PAKE between the new client and the approving trusted endpoint. [SPAKE2, RFC 9382](https://www.rfc-editor.org/rfc/rfc9382.html#section-3.3), binds identities into its transcript and requires mutual key confirmation. Its integration must bind the admission request, endpoint public keys, account and role into the confirmed exchange or subsequent authenticated messages. The exact composition needs review.

The human-transferred secret must originate at an endpoint and remain hidden from the relay. A separate public rendezvous identifier can locate messages. Sending the complete secret to the relay as a lookup code destroys that protection. Trusted endpoints must enforce attempt limits, short request lifetime and one successful approval; PAKE still permits online guessing. The server command must show the action being approved and require Gordon's explicit action. A QR or long secret can reduce guessing risk where convenient without making the command workflow unusable.

The unanswered implementation question is a maintained, reviewed PAKE implementation interoperating across Apple clients and the eventual server platforms. SPAKE2's RFC does not certify a particular library or MyTerm's enrollment composition. Do not replace this with a home-grown short-code key exchange if the library investigation fails.

## Directory delivery and revocation

Candidate: encrypt an authenticated directory snapshot using an account directory key, with individually addressed key envelopes for current members. Admission completes at an available approver, which supplies authenticated membership evidence, account identity, directory access and a current checkpoint. Other servers can verify it when they return; they need no second manual approval. All these payloads may transit the relay as ciphertext.

On removal, stop envelopes to that endpoint and generate fresh directory key material for remaining members. Re-encrypt the current snapshot if its future version must remain private. Copied keys and old ciphertext remain readable; revocation cannot erase them. Concurrent membership changes and directory-key rotation need coordination so a stale authority cannot publish a newer-looking snapshot that gives a removed device the new key. These are requirements inferred from the threat model, not properties supplied by HPKE.

Persist verified account identity, membership evidence, revocations and checkpoints across restart. Exchange authenticated updates over direct connections too. Version numbers alone cannot prove that unseen updates do not exist or distinguish concurrent writers assigning the same next number. [Certificate Transparency's consistency proofs](https://www.rfc-editor.org/rfc/rfc9162.html#section-2.1.4) show an established append-only-history mechanism; they do not supply freshness or account authorization. A private deployment would also need a defined comparison/witness policy to detect split histories.

The agreed indefinite offline access means revocation has no maximum propagation delay. Once an honest server receives a valid revocation it must disconnect the client while preserving processes, remember the removal and refuse silent re-enrollment. A compromised removed endpoint cannot be forced to acknowledge removal; honest peers enforce the boundary. Reinstallation with lost checkpoints needs a current trusted bootstrap, not relay-only rollback prevention.

Multi-authority conflicts require a decision. Suppose A removes B while partitioned B admits C. A signature timestamp cannot establish whether the admission preceded removal when B controls its signing key. Should C lose access when B's removal arrives? What if A and B remove each other? A remove-wins rule, loss of descendants, or serialization through an available authority has different consequences for availability and accidental lockout. Cryptographic verification alone cannot choose them.

## Unattended enrollment and issuance availability

The following are deductions from clonable credentials and the absence of trusted shared state. They distinguish a single authorized identity from a globally single redemption.

| Credential arrangement | Trusted issuer needed at enrollment? | Consequence |
| --- | --- | --- |
| Authorization pre-bound to a particular instance's public keys | No, if necessary membership and directory-key material were prepared securely | Replays authorize only those keys. Cloning their private keys clones the identity; image cloning remains prohibited. |
| Generic single-use bearer invitation for an unknown future instance | Yes, for authoritative allocation unless another trusted single-redemption mechanism is introduced | A designated issuer must atomically record redemption and bind it to the generated subject keys. Relay-only consumption cannot enforce this. |
| Generic invitation accepted by independent, partitioned issuers | Coordination is required for strict single use | Each issuer can accept a separate redemption before learning about the other. Local consumed flags do not make a global limit. |
| Reusable delegated enrollment capability | Can avoid an online issuer if it includes sufficient verifiable issuance authority | Every holder can generate admissions within its scope. Revocation and expiry are limited by verifiers' knowledge and clock assumptions. |

An offline bearer token with no delegated signing capability, no existing issuer and no pre-bound subject cannot obtain a new trusted signature merely by asking the relay. Conversely, pre-authorizing known public keys can work without a live issuer; obtaining those genuine per-instance keys becomes a provisioning step.

A credential scoped only to enrollment is still highly sensitive: admitted servers inherit the already agreed powers to approve clients and revoke devices. Supporting separate deployment credentials needs independent identifiers, limits, expiry and revocation evidence. Expiring an invitation must not silently expire all servers it previously enrolled. The semantics of revoking their issuer are a separate decision.

## Implementation feasibility and decisions

[SwiftNIO SSL](https://github.com/apple/swift-nio-ssl) supplies Swift TLS client/server handlers backed by BoringSSL. Its [current context source](https://github.com/apple/swift-nio-ssl/blob/main/Sources/NIOSSL/SSLContext.swift) has Darwin/Linux/Android branches and an unsupported-OS fallback; it is not evidence of native Windows server support. Apple client builds and nested-stream handling need a prototype.

[Go crypto/tls](https://pkg.go.dev/crypto/tls) has stream-based client/server APIs and `VerifyConnection`, which runs even on resumed connections. [Rustls](https://github.com/rustls/rustls) supplies TLS with platform-dependent crypto providers, transport-independent I/O and [traffic-key refresh](https://docs.rs/rustls/latest/rustls/struct.ConnectionCommon.html#method.refresh_traffic_keys). These permit different server-runtime choices; validate the selected provider, Windows target, client authentication and rekey controls before committing to one. Authorization must be rechecked on resumption and live revocation.

Noise implementations include [flynn/noise](https://github.com/flynn/noise) for Go and [Snow](https://github.com/mcginty/snow) for Rust. Snow explicitly reports no formal audit. Their existence does not establish a reviewed Apple integration. [CryptoKit HPKE](https://developer.apple.com/documentation/cryptokit/hpke) is relevant to existing Apple code; [Swift Crypto](https://github.com/apple/swift-crypto) supplies a substantial cross-platform CryptoKit surface but does not promise every API or Windows architecture.

Gordon's remaining decisions are:

1. Must generic unattended enrollment succeed when every existing trusted endpoint is offline, or may it wait for a designated trusted issuer? Pre-bound per-instance authorization is a separate option with provisioning work.
2. How should removing an authority affect its earlier or concurrent admissions and deployment credentials, and how should mutually conflicting removals resolve?
3. Is fresh authenticated connection replacement sufficient recovery from temporary traffic-state exposure, or is continuous ratchet recovery required? Identity compromise still requires revocation and re-enrollment.

After those answers, specify the trust state machine and short-code ceremony, then prototype one Apple client against candidate native servers. Exercise malicious relay substitutions, forked state, duplicate invitation redemption, offline revocation and reconnects. Obtain independent protocol review before treating the composed account system as secure. This research adds no recovery-key requirement and leaves the settled account-loss policy intact.
