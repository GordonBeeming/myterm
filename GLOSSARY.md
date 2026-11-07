# MyTerm

MyTerm connects a person's clients to workspaces on their servers.

## Language

**Personal account**:
One person's directory of their MyTerm servers. Workspaces and sessions belong to the servers.
_Avoid_: Team, organization

**MyTerm server**:
An independently running instance of MyTerm that belongs to one personal account and owns workspaces and their sessions. One machine can run multiple MyTerm servers.
_Avoid_: Mac host

**MyTerm client**:
The Mac, iPhone or iPad interface a person uses to access a MyTerm server.
_Avoid_: Server, host

**Workspace**:
A named collection of work belonging to one MyTerm server, available to the person's connected clients.

**Approved client**:
A MyTerm client authorized to access a personal account's servers. Signing in alone does not grant approval; an additional client needs approval from an already trusted client or enrolled server belonging to that account.

**Terminal session**:
A terminal and its process owned by a MyTerm server. A client chooses the server on which to launch it and can attach to it; the client does not own the process.

**Deployment credential**:
An account-owned authorization for enrolling MyTerm servers in an automated deployment. It has its own usage policy, expiry and revocation, and survives ordinary removal of the device that created it.
