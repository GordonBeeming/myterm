# MyTerm

MyTerm provides local sessions and connects a person's clients to a shared account layout and sessions on their servers.

## Language

**Relay operator**:
The person running a MyTerm relay deployment. We operate the default hosted relays; a person running their own relay operates that deployment. Operator access does not grant approval to a personal account's clients or servers.

**Personal account**:
One person's MyTerm server directory and shared layout. Each terminal or browser session belongs to its assigned server.
_Avoid_: Team, organization

**MyTerm server**:
An independently running instance of MyTerm that owns the terminal and browser sessions assigned to it. It can run locally before account setup; once enrolled, it belongs to exactly one personal account, and one machine can run multiple MyTerm servers.
_Avoid_: Mac host

**MyTerm client**:
The Mac, iPhone or iPad interface a person uses to access a local layout or their account layout and sessions across MyTerm servers.
_Avoid_: Server, host

**Workspace**:
A named collection of work within a local or account layout. In an account layout, its terminal and browser sessions may belong to different MyTerm servers.

**Local layout**:
The folder, workspace, pane and tab structure used before connecting local work to a personal account. Its sessions belong to a local MyTerm server.

**Account layout**:
A personal account's shared folder, workspace, pane and tab structure. Each client keeps its own navigation, focus and display preferences while shared structural changes appear across clients.

**Pane content**:
An individually identified terminal or browser item displayed in a workspace pane and assigned to one MyTerm server.

**Approved client**:
A MyTerm client authorized to access a personal account's servers. Signing in alone does not grant approval; an additional client needs approval from an already trusted client or enrolled server belonging to that account.

**Terminal session**:
A terminal and its process owned by a MyTerm server. A client chooses the server on which to launch it and can attach to it; the client does not own the process.

**Enrollment credential**:
An account-owned authorization to enroll MyTerm servers, issued by a trusted client or enrolled server. It may authorize a single enrollment or reusable deployment enrollment.

**Deployment credential**:
An account-owned authorization for enrolling MyTerm servers in an automated deployment. It has its own usage policy, expiry and revocation, and survives ordinary removal of the device that created it.

**Relay access**:
A MyTerm server's explicitly enabled participation in its personal account through the relay. Account membership alone does not mean relay access is enabled.

**Connection path**:
The same-machine local, explicitly configured direct, or relay route a MyTerm client uses to reach one MyTerm server. Changing the path preserves the server's identity and ownership of its sessions.
