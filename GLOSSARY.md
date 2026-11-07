# MyTerm

MyTerm connects a person's clients to a shared account layout and sessions on their servers.

## Language

**Personal account**:
One person's MyTerm server directory and shared layout. Each terminal or browser session belongs to its assigned server.
_Avoid_: Team, organization

**MyTerm server**:
An independently running instance of MyTerm that belongs to one personal account and owns the terminal and browser sessions assigned to it. One machine can run multiple MyTerm servers.
_Avoid_: Mac host

**MyTerm client**:
The Mac, iPhone or iPad interface a person uses to access their account layout and sessions across MyTerm servers.
_Avoid_: Server, host

**Workspace**:
A named collection of work within a personal account's shared layout. Its terminal and browser sessions may belong to different MyTerm servers.

**Account layout**:
A personal account's shared folder, workspace, pane and tab structure. Each client keeps its own navigation, focus and display preferences while shared structural changes appear across clients.

**Pane content**:
An individually identified terminal or browser item displayed in a workspace pane and assigned to one MyTerm server.

**Approved client**:
A MyTerm client authorized to access a personal account's servers. Signing in alone does not grant approval; an additional client needs approval from an already trusted client or enrolled server belonging to that account.

**Terminal session**:
A terminal and its process owned by a MyTerm server. A client chooses the server on which to launch it and can attach to it; the client does not own the process.

**Deployment credential**:
An account-owned authorization for enrolling MyTerm servers in an automated deployment. It has its own usage policy, expiry and revocation, and survives ordinary removal of the device that created it.
