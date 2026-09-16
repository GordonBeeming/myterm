# Set up the MyTerm proxy with Cloudflare Tunnel

Run independent dev and prod relays on one Linux server, with `cloudflared` installed on the host. Cloudflare provides the public HTTPS endpoint; the tunnel forwards requests to HTTP listeners on the server's loopback interface. There is no Caddy or server certificate setup.

The relay connects running MyTerm Macs to the companion app. It does not run shells. A Mac that is asleep, offline, or no longer running MyTerm is unavailable.

## Before you start

- A Linux server with SSH access and `sudo`. The installation commands below target Ubuntu 24.04 LTS with systemd and standard, rootful Docker Engine.
- A domain active in your Cloudflare account, and permission to create tunnels and DNS routes.
- A published MyTerm release containing the Linux relay image archives, plus compatible Mac and companion builds.
- For physical-device testing, Xcode and Apple signing configuration as described in [the companion guide](COMPANION.md).

## 1. Choose your environment names

Replace `example.com` throughout this guide with your domain. Use stable hostnames: passkeys are scoped to the relay's relying-party ID (RP ID).

| Setting | Dev | Prod |
|---|---|---|
| Public hostname | `relay-dev.example.com` | `relay.example.com` |
| Public origin | `https://relay-dev.example.com` | `https://relay.example.com` |
| RP ID | `relay-dev.example.com` | `relay.example.com` |
| Host listener | `127.0.0.1:8788` | `127.0.0.1:8787` |
| Container | `myterm-relay-dev` | `myterm-relay-prod` |
| Persistent data | `/srv/myterm-relay-dev` | `/srv/myterm-relay-prod` |
| Docker subnet | `172.30.88.0/24` | `172.30.87.0/24` |
| Docker gateway | `172.30.88.1` | `172.30.87.1` |
| Trusted proxy CIDR | `172.30.88.1/32` | `172.30.87.1/32` |

Each relay has one owner account and can serve several Macs. Register a separate passkey for each environment; both can live in Apple Passwords. Keep the RP ID equal to the exact hostname rather than broadening it to the parent domain.

One tunnel can carry both routes. The server and tunnel are shared failure points, while containers and databases remain separate. For prod only, omit the dev environment and its route.

## 2. Install Docker on the Linux server

All commands in this section run over SSH on the server. If Docker Engine and the Compose plugin are already installed, verify them and skip installation. On a server with an existing container runtime, follow Docker's migration guidance before changing packages.

The following uses [Docker's official Ubuntu repository](https://docs.docker.com/engine/install/ubuntu/):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker version
sudo docker compose version
```

Preserve existing SSH/firewall rules. This deployment needs no inbound ports for web traffic, including 80, 443, 8787, and 8788. Other services on the server may still need their existing rules.

If outbound traffic is restricted, allow DNS, HTTPS for package/image downloads, and Cloudflare Tunnel traffic on TCP/UDP 7844. Use Cloudflare's current destination list in [Tunnel with firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/).

## 3. Download a published relay release

Install from [MyTerm Releases](https://github.com/GordonBeeming/myterm/releases). Choose a version whose assets include both `myterm-relay-VERSION-linux-ARCH.docker.tar.gz` and its `.sha256` file. The archive contains a prebuilt Docker image; the server needs no source checkout, Git, or compiler.

On the Linux server, set `RELAY_VERSION` to the numeric version of the release you selected (omit the leading `v`). Replace `REPLACE_WITH_RELEASE_VERSION` before running:

```bash
RELAY_VERSION='REPLACE_WITH_RELEASE_VERSION'
case "$(uname -m)" in
  x86_64) RELAY_ARCH=amd64 ;;
  aarch64|arm64) RELAY_ARCH=arm64 ;;
  *) echo 'Supported server architectures: x86_64 and ARM64' >&2; exit 1 ;;
esac
RELAY_ASSET="myterm-relay-${RELAY_VERSION}-linux-${RELAY_ARCH}.docker.tar.gz"
RELAY_DOWNLOAD="https://github.com/GordonBeeming/myterm/releases/download/v${RELAY_VERSION}"
mkdir -p "$HOME/myterm-relay-downloads/$RELAY_VERSION"
cd "$HOME/myterm-relay-downloads/$RELAY_VERSION"
curl --fail --show-error --location --output "$RELAY_ASSET" \
  "$RELAY_DOWNLOAD/$RELAY_ASSET"
curl --fail --show-error --location --output "$RELAY_ASSET.sha256" \
  "$RELAY_DOWNLOAD/$RELAY_ASSET.sha256"
sha256sum --check "$RELAY_ASSET.sha256" && sudo docker load --input "$RELAY_ASSET"
RELAY_IMAGE="myterm-relay:${RELAY_VERSION}-linux-${RELAY_ARCH}"
sudo docker image inspect "$RELAY_IMAGE" --format '{{.RepoTags}} {{.Architecture}}'
printf 'Use this image in each new environment file: %s\n' "$RELAY_IMAGE"
```

Stop on a failed download or checksum check. Expect `OK` from the checksum check and the matching architecture from image inspection. The checksum detects corruption; download both files from the official release over HTTPS. Keep the printed image tag for the next step. Private forks need authenticated release downloads.

## 4. Configure the relay instances

Choose the configuration layout before creating directories. UID 65532 is the non-root account used by the relay image.

For a fresh two-instance setup, create the shared configuration directory and both data directories:

```bash
RELAY_CONFIG_DIR=/opt/myterm-relay
sudo install -d -m 0755 "$RELAY_CONFIG_DIR"
sudo install -d -m 0700 -o 65532 -g 65532 \
  /srv/myterm-relay-dev /srv/myterm-relay-prod
```

If `/opt/myterm-relay` already belongs to a separately managed dev installation, leave its configuration and data unchanged. Create only the isolated prod configuration and data directories:

```bash
RELAY_CONFIG_DIR=/opt/myterm-relay-prod
sudo install -d -m 0755 "$RELAY_CONFIG_DIR"
sudo install -d -m 0700 -o 65532 -g 65532 /srv/myterm-relay-prod
```

For this isolated layout, use `/opt/myterm-relay-prod/compose.yaml` instead of the path in the next command, and create `/opt/myterm-relay-prod/prod.env` instead of the prod path shown below. Skip the `dev.env`, dev startup, and dev limiter-probe steps. Do not recreate or restart dev. The prod port, project, container, and network names remain the values shown below.

The host-to-container connection reaches the relay from Docker's bridge gateway, not from `127.0.0.1`. The relay may trust `X-Forwarded-For` only for that socket peer. This guide assigns a separate bridge and fixed gateway to each environment so the trusted `/32` remains stable across container recreation.

Check that the proposed subnets do not overlap a host route or an existing Docker network:

```bash
ip -4 route show
sudo docker network inspect $(sudo docker network ls -q) \
  --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}'
```

For a fresh two-instance setup, both proposed subnets must be unused. If either is already present, choose two unused private `/24` networks, keep each gateway as the first address in its subnet, and update both environment files below.

For an isolated prod setup, check and choose only the prod subnet. Any existing dev network, including one at `172.30.88.0/24`, must remain unchanged. If `172.30.87.0/24` conflicts, choose one unused private `/24`, keep its gateway as the first address, and update only `/opt/myterm-relay-prod/prod.env`.

Do not widen a trusted value to the whole Docker subnet: connections through the host's published loopback port appear from the gateway. Any process on the server can reach that loopback listener and supply headers, so the server itself remains part of the trusted administrative boundary.

Save the following Compose template in the configuration directory for the selected layout:

```bash
sudo tee "${RELAY_CONFIG_DIR:?Choose a configuration layout first}/compose.yaml" \
  > /dev/null <<'YAML'
services:
  relay:
    image: ${RELAY_IMAGE:?Set RELAY_IMAGE}
    container_name: myterm-relay-${RELAY_ENV:?Set RELAY_ENV}
    restart: unless-stopped
    user: "65532:65532"
    read_only: true
    tmpfs:
      - /tmp
    ports:
      - "127.0.0.1:${RELAY_PORT:?Set RELAY_PORT}:8787"
    networks:
      - relay-network
    volumes:
      - type: bind
        source: /srv/myterm-relay-${RELAY_ENV}
        target: /data
        bind:
          create_host_path: false
    environment:
      MYTERM_RELAY_PUBLIC_URL: https://${RELAY_HOST:?Set RELAY_HOST}
      MYTERM_RELAY_RP_ID: ${RELAY_HOST}
      MYTERM_RELAY_RP_NAME: ${RELAY_NAME:?Set RELAY_NAME}
      MYTERM_RELAY_LISTEN: 0.0.0.0:8787
      MYTERM_RELAY_DATABASE: /data/relay.sqlite3
      MYTERM_RELAY_TRUSTED_PROXY_CIDRS: ${RELAY_GATEWAY:?Set RELAY_GATEWAY}/32
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  relay-network:
    name: myterm-relay-${RELAY_ENV:?Set RELAY_ENV}-network
    driver: bridge
    ipam:
      config:
        - subnet: ${RELAY_SUBNET:?Set RELAY_SUBNET}
          gateway: ${RELAY_GATEWAY:?Set RELAY_GATEWAY}
YAML
```

For a fresh two-instance setup, create both files below with `sudoedit`. For an isolated prod setup, skip `dev.env` and create only `/opt/myterm-relay-prod/prod.env`. Replace the image placeholder with the exact tag printed after loading the release image, and replace each new hostname.

`/opt/myterm-relay/dev.env`:

```dotenv
RELAY_ENV=dev
RELAY_NAME=MyTerm Dev
RELAY_HOST=relay-dev.example.com
RELAY_PORT=8788
RELAY_SUBNET=172.30.88.0/24
RELAY_GATEWAY=172.30.88.1
RELAY_IMAGE=myterm-relay:REPLACE_WITH_RELEASE_VERSION-linux-REPLACE_WITH_ARCH
```

`${RELAY_CONFIG_DIR}/prod.env`, which is `/opt/myterm-relay/prod.env` for a fresh setup or `/opt/myterm-relay-prod/prod.env` for an isolated prod setup:

```dotenv
RELAY_ENV=prod
RELAY_NAME=MyTerm
RELAY_HOST=relay.example.com
RELAY_PORT=8787
RELAY_SUBNET=172.30.87.0/24
RELAY_GATEWAY=172.30.87.1
RELAY_IMAGE=myterm-relay:REPLACE_WITH_RELEASE_VERSION-linux-REPLACE_WITH_ARCH
```

These files contain deployment settings only. Do not add passkeys or tunnel tokens. They are outside the checkout and should remain outside Git.

For a fresh two-instance setup, start and verify dev first. Skip this startup and its limiter probe in an isolated prod setup; the existing dev container must keep running unchanged.

```bash
cd /opt/myterm-relay
sudo docker compose --env-file dev.env -p myterm-relay-dev config --quiet
sudo docker compose --env-file dev.env -p myterm-relay-dev up -d
curl --fail http://127.0.0.1:8788/healthz
sudo docker inspect myterm-relay-dev \
  --format '{{range .NetworkSettings.Networks}}{{println .Gateway}}{{end}}'
```

Verify that the relay uses separate limiter keys behind the published port. These requests deliberately omit the required login parameters, so HTTP 400 means the request reached normal validation. Ten requests consume the burst for one reserved test address. Its next request must return 429, while the different address must still return 400:

```bash
(
set -eu
for attempt in $(seq 1 10); do
  STATUS=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --header 'Host: relay-dev.example.com' \
    --header 'X-Forwarded-For: 192.0.2.10' \
    http://127.0.0.1:8788/auth/login)
  printf 'test client A request %s: HTTP %s\n' "$attempt" "$STATUS"
  test "$STATUS" = 400
done

STATUS=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header 'Host: relay-dev.example.com' \
  --header 'X-Forwarded-For: 192.0.2.10' \
  http://127.0.0.1:8788/auth/login)
printf 'test client A rate-limit request: HTTP %s\n' "$STATUS"
test "$STATUS" = 429

STATUS=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --header 'Host: relay-dev.example.com' \
  --header 'X-Forwarded-For: 198.51.100.20' \
  http://127.0.0.1:8788/auth/login)
printf 'test client B: HTTP %s\n' "$STATUS"
test "$STATUS" = 400
)
```

Replace the example hostname in these headers with your dev hostname. Client A's rate-limit request must return 429. If client B returns 429, stop and inspect the container gateway. Do not continue to owner enrollment until client B returns 400.

Then start prod:

Run this from `/opt/myterm-relay` for the fresh two-instance setup, or `/opt/myterm-relay-prod` when preserving an existing separately managed dev installation.

```bash
cd "${RELAY_CONFIG_DIR:?Choose a configuration layout first}"
sudo docker compose --env-file prod.env -p myterm-relay-prod config --quiet
sudo docker compose --env-file prod.env -p myterm-relay-prod up -d
curl --fail http://127.0.0.1:8787/healthz
sudo docker inspect myterm-relay-prod \
  --format '{{range .NetworkSettings.Networks}}{{println .Gateway}}{{end}}'
sudo docker ps --filter name=myterm-relay
```

Run the same limiter probe against prod after it starts, replacing `relay-dev.example.com` with the prod hostname and port `8788` with `8787`. The first ten client A requests must return 400, its next request must return 429, and client B must return 400.

Each health check you ran should return HTTP 200. `/healthz` proves the HTTP service responds; it does not check database health or successful authentication. The published ports should show `127.0.0.1`, not `0.0.0.0` or `[::]`. Each inspect command must print the `RELAY_GATEWAY` from its environment file. Stop and fix the network when it differs; otherwise the relay will ignore forwarded client addresses and share one limiter bucket.

Always pass the matching `--env-file` and `-p` arguments. They keep Compose operations scoped to one environment.

## 5. Create or reuse the Cloudflare Tunnel

Use the [Cloudflare dashboard tunnel instructions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/). Dashboard labels can change; look for **Networking → Tunnels** and a **cloudflared** connector.

For a fresh two-instance setup, create or reuse a tunnel and configure both environments in the next section. For an isolated prod setup, reuse the healthy tunnel and connector already serving dev without reinstalling or restarting it. If prod requires a separate tunnel, create one for prod only and leave the existing dev connector and route unchanged.

When a tunnel must be created, follow these steps. An isolated prod setup that reuses the existing healthy tunnel skips its creation and installation and only verifies step 4.

1. Create a remotely managed tunnel, for example `myterm-server`. If this server already has a healthy cloudflared tunnel, reuse it and skip installing another service.
2. Select the Linux distribution and architecture matching the server.
3. Run the dashboard's package-installation and service-installation commands on the server. Install cloudflared on the **host**, so it can reach the loopback ports above. The dashboard provides the actual tunnel token; no token belongs in this guide or the repository.
4. Wait for the connector to show **Healthy**.

Treat the installation command containing the tunnel token as a secret. Keep it out of shared logs, screenshots, shell history, and support messages. If exposed, rotate the token through Cloudflare and update the connector. The [official package repository](https://pkg.cloudflare.com/) also lists installation commands.

Verify the host service:

```bash
sudo systemctl is-active cloudflared
sudo systemctl is-enabled cloudflared
```

If it fails, inspect `sudo journalctl -u cloudflared -n 100 --no-pager` locally. Review logs for secrets before sharing them.

Do not use an ephemeral Quick Tunnel: passkeys and saved connections need a stable public hostname. If you run cloudflared inside Docker instead, `127.0.0.1` points at that container; the route addresses in this guide assume a host service.

## 6. Publish the required Cloudflare routes

For a fresh two-instance setup, open the tunnel's **Routes** tab, choose **Add route → Published application**, and add both entries:

| Public hostname | Service type | Service URL | Path |
|---|---|---|---|
| `relay-dev.example.com` | HTTP | `127.0.0.1:8788` | Leave empty |
| `relay.example.com` | HTTP | `127.0.0.1:8787` | Leave empty |

For an isolated prod setup, leave the existing dev route unchanged and add only the prod entry:

| Public hostname | Service type | Service URL | Path |
|---|---|---|---|
| `relay.example.com` | HTTP | `127.0.0.1:8787` | Leave empty |

If the dashboard uses a single service URL field, enter `http://127.0.0.1:8788` or `http://127.0.0.1:8787`. Keep origin settings at their defaults; no origin TLS or hostname override is needed.

The published routes create tunnel DNS records. Do not add A/AAAA records pointing these names at the server. If a chosen name already has a DNS record, check what uses it before replacing it. Use a different unused name when in doubt.

The current MyTerm clients authenticate with the relay's passkeys and do not implement an extra Cloudflare Access session or service-token exchange. Do not put an Access login in front of the relay routes. Keep unrelated Access applications unchanged.

For each new hostname, ensure existing cache rules do not cache relay responses and browser-challenge rules do not interrupt native API requests. Check that WebSockets are enabled for the zone; they carry terminal traffic. Scope any rule adjustment to the new relay hostname. In an isolated prod setup, leave rules for the existing dev hostname unchanged. See [Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/).

From your Mac, check both public endpoints after a fresh two-instance setup, using your own hostnames:

```bash
curl --fail --show-error https://relay-dev.example.com/healthz
curl --fail --show-error https://relay.example.com/healthz
```

After an isolated prod setup, check only the new prod endpoint:

```bash
curl --fail --show-error https://relay.example.com/healthz
```

Expect HTTP 200 from each endpoint you checked, with no Access login page, browser challenge, or redirect. Do not use `curl -k`. Cloudflare handles public HTTPS; the relay's configured public origin remains `https://...` even though the local service uses HTTP.

Cloudflare supplies `X-Forwarded-For` to HTTP origins. The relay accepts that header here because Docker presents the configured gateway `/32` as the immediate peer. It then walks the address chain from right to left and uses the first untrusted address, so a visitor cannot choose the limiter key by adding a value on the left. Keep Cloudflare's visitor-IP headers enabled for these routes. Do not add `CF-Connecting-IP` rewriting at the relay, and do not trust arbitrary bridge or Cloudflare address ranges for this host-local tunnel topology.

## 7. Enroll the owner and connect the Mac

### Fresh two-instance setup

On the Linux server, generate a dev enrollment link:

```bash
sudo docker exec myterm-relay-dev \
  /app/myterm-relay bootstrap-owner --expires 15m
```

On your Mac, open the compatible **myterm-dev** build and go to **Settings → Companion**:

1. Paste the complete generated URL, including its fragment, into **Relay address or setup link**.
2. Choose **Continue** and complete passkey registration in the system browser.
3. MyTerm connects automatically. Confirm the status says **Connected**; phone pairing controls now appear.

Keep the bootstrap link private. It expires after 15 minutes and is consumed during registration. Opening it directly without the Mac app's authentication parameters does not complete Mac sign-in.

Repeat for prod with the **myterm** build, the prod hostname, and:

```bash
sudo docker exec myterm-relay-prod \
  /app/myterm-relay bootstrap-owner --expires 15m
```

### Isolated prod setup

Reuse the existing dev owner, passkeys, route, and connected Macs without changing them. Do not run `bootstrap-owner`, `add-passkey`, or `recover-owner` against `myterm-relay-dev`.

Generate an enrollment link only for the new prod relay:

```bash
sudo docker exec myterm-relay-prod \
  /app/myterm-relay bootstrap-owner --expires 15m
```

Open the compatible **myterm** build on the Mac, paste the complete generated prod URL into **Relay address or setup link**, and complete passkey registration. Confirm that prod connects without signing out, re-enrolling, or otherwise changing the existing dev connection.

For another Mac on an existing environment, enter the relay address in **Relay address or setup link** and choose **Continue** using that environment's passkey. You do not bootstrap the account again. Each Mac registers its own host identity.

## 8. Install and pair the companion

Use compatible desktop and mobile builds from the same release. For source builds, follow [Build and test](COMPANION.md#build-and-test). For a fresh two-instance setup, these commands create separate dev and prod Mac bundles:

```bash
bash script/build_and_run.sh --bundle
bash script/build_and_run.sh --prod --bundle
```

For an isolated prod setup, build or install only the prod bundle and leave the existing dev app and connection unchanged:

```bash
bash script/build_and_run.sh --prod --bundle
```

After a fresh setup, open the bundle for the environment being configured: `dist/myterm-dev.app` or `dist/myterm.app`. After an isolated prod setup, open only `dist/myterm.app` and leave the existing dev app running. Quit an existing instance of the chosen channel before opening a rebuilt bundle; a second normal launch focuses the existing instance.

Open `Companion/MyTermCompanion.xcodeproj` in Xcode, select the `MyTermCompanion` scheme, configure your Apple development team for the app and notification extension, and run on your iPhone or iPad. Both targets need their shared Keychain and App Group configuration. The current app requires iOS/iPadOS 26 or later.

Pair each newly configured Mac. Complete both environments after a fresh setup; in an isolated prod setup, pair only the new prod connection:

1. In the connected Mac's Companion settings, choose **Start Pair Mode**.
2. In the phone app, choose **Add Mac** and scan its QR code.
3. Complete passkey sign-in for that relay.
4. Approve **Pair this phone?** on the Mac.
5. Select the saved Mac, open a workspace and terminal, and take control when needed.

The QR code refreshes every 30 seconds. Each code stays valid for 60 seconds, so the previous and current codes overlap. Each code can be used only once. Scan the current code if pairing expires. Pair the iPad separately. One companion installation can retain connections to both relays and multiple Macs; separate side-by-side dev/prod iOS bundle identities are not configured in the current project.

## 9. Test before using real workspaces

Use synthetic terminal output and disposable folders during testing.

For a fresh two-instance setup, test both environments and switching between them. For an isolated prod setup, run the prod tests only. Do not restart, re-pair, or modify dev; observe that its existing container and client connection remain available while prod is tested.

| Test | Expected result |
|---|---|
| Disable phone Wi-Fi and connect over cellular | The Mac is reachable through the cloud relay. |
| Type, scroll, and resize for several minutes | Output and control remain usable, including beyond the 30-second control lease. |
| View one terminal from phone and iPad | One has control; the other watches. Explicit takeover updates both views. |
| Take control back on the Mac | The phone reflects the loss of control. |
| Switch between dev, prod, and another Mac | Workspace and terminal identities stay with the selected host. |
| Rename, move, or split a test terminal | The Mac reflects changes and the shell continues running. |
| Rotate the phone or resize the iPad scene | Navigation adapts to the available width. |
| Restart the relay being tested | It reconnects without pairing again. In a fresh setup, the other relay stays connected. |
| Sleep or quit one Mac | That host becomes unavailable; other hosts remain reachable. |
| Revoke a paired device on the Mac | The device loses access to that host. |

## 10. Day-to-day operations

### Inspect or restart one environment

For a fresh two-instance setup, choose the environment you intend to operate. This example restarts dev:

```bash
sudo docker logs --tail 100 myterm-relay-dev
sudo docker restart myterm-relay-dev
curl --fail http://127.0.0.1:8788/healthz
```

For prod, use `myterm-relay-prod` and port `8787`. In an isolated prod setup, operate only prod:

```bash
sudo docker logs --tail 100 myterm-relay-prod
sudo docker restart myterm-relay-prod
curl --fail http://127.0.0.1:8787/healthz
```

Restarting a relay interrupts that environment's sockets. Restarting cloudflared interrupts both environments.

### Back up the database

Keep each environment's backup separate. A brief stopped-container backup avoids copying SQLite database and WAL files at inconsistent points. For a fresh two-instance setup, this example backs up dev:

```bash
sudo install -d -m 0700 /srv/myterm-relay-backups
BACKUP_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
sudo docker stop myterm-relay-dev
sudo tar -C /srv -czf "/srv/myterm-relay-backups/dev-${BACKUP_STAMP}.tar.gz" \
  myterm-relay-dev
sudo docker start myterm-relay-dev
sudo test -s "/srv/myterm-relay-backups/dev-${BACKUP_STAMP}.tar.gz"
```

Check every command's result. If archiving fails, restart the container and investigate before upgrading. In a fresh two-instance setup, repeat separately for prod, changing the container, directory, and archive prefix.

In an isolated prod setup, leave dev running and back up only prod:

```bash
sudo install -d -m 0700 /srv/myterm-relay-backups
BACKUP_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
sudo docker stop myterm-relay-prod
sudo tar -C /srv -czf "/srv/myterm-relay-backups/prod-${BACKUP_STAMP}.tar.gz" \
  myterm-relay-prod
sudo docker start myterm-relay-prod
sudo test -s "/srv/myterm-relay-backups/prod-${BACKUP_STAMP}.tar.gz"
```

Store an encrypted copy off the server and test restoration using an isolated test deployment. Never start a restored prod database as a second live prod relay.

### Upgrade one or both environments

For a fresh two-instance setup:

1. Back up the environment being upgraded and record its current `RELAY_IMAGE`.
2. Download, verify, and load the chosen release using step 3. Keep the current image available for rollback.
3. Change only `RELAY_IMAGE` in `/opt/myterm-relay/dev.env`.
4. Apply and verify dev:

```bash
cd /opt/myterm-relay
sudo docker compose --env-file dev.env -p myterm-relay-dev config --quiet
sudo docker compose --env-file dev.env -p myterm-relay-dev up -d
curl --fail http://127.0.0.1:8788/healthz
```

Repeat the pairing/sign-in and terminal checks before changing `RELAY_IMAGE` in `/opt/myterm-relay/prod.env`, then apply and verify prod:

```bash
cd /opt/myterm-relay
sudo docker compose --env-file prod.env -p myterm-relay-prod config --quiet
sudo docker compose --env-file prod.env -p myterm-relay-prod up -d
curl --fail http://127.0.0.1:8787/healthz
```

For an isolated prod setup, skip every dev upgrade step above:

1. Back up prod and record its current `RELAY_IMAGE`.
2. Download, verify, and load the chosen release using step 3. Keep the current prod image available for rollback.
3. Change only `RELAY_IMAGE` in `/opt/myterm-relay-prod/prod.env`.
4. Apply and verify prod from its isolated configuration directory:

```bash
cd /opt/myterm-relay-prod
sudo docker compose --env-file prod.env -p myterm-relay-prod config --quiet
sudo docker compose --env-file prod.env -p myterm-relay-prod up -d
curl --fail http://127.0.0.1:8787/healthz
```

Keep previous images until the upgrade is verified. Do not delete persistent directories during upgrades.

If a release has no incompatible database migration, restore the previous image tag and run `up -d`. If database compatibility changed, follow that release's rollback instructions and restore the matching backup while the relay is stopped. A backup restore can discard changes made after the backup, so plan the rollback before upgrading.

### Add or recover a passkey

In a fresh two-instance setup, these examples operate dev. To add a passkey while preserving existing credentials:

```bash
sudo docker exec myterm-relay-dev \
  /app/myterm-relay add-passkey --expires 15m
```

If all owner passkeys are lost:

```bash
sudo docker exec myterm-relay-dev \
  /app/myterm-relay recover-owner --expires 15m
```

Choose **Change relay or recover passkey…**, paste the generated link into **Relay address or setup link**, and choose **Continue**. Recovery replaces the credential set and revokes relay sessions only after the new credential is verified. Sign apps in again afterward. Substitute the prod container for either credential operation when operating prod.

In an isolated prod setup, leave dev credentials and sessions unchanged. Run the required command only against `myterm-relay-prod`:

```bash
sudo docker exec myterm-relay-prod \
  /app/myterm-relay add-passkey --expires 15m
```

Only if all prod owner passkeys are lost, run recovery instead:

```bash
sudo docker exec myterm-relay-prod \
  /app/myterm-relay recover-owner --expires 15m
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Container exits immediately | Inspect its logs, hostname settings, and `/srv/myterm-relay-ENV` ownership (UID 65532, mode 0700). |
| Local health check fails | Confirm the container is running and the port matches its environment. Fix this before changing Cloudflare. |
| Tunnel is unhealthy | Check cloudflared's service and outbound connectivity. |
| Cloudflare returns 502 | Verify local health; route to HTTP and the correct loopback port. Check whether cloudflared accidentally runs in a container. |
| Hostname does not resolve | Check the published route and conflicting DNS records. |
| Login HTML or a challenge appears instead of the API response | Check Access, WAF/challenge, redirect, and cache rules for this hostname. |
| Passkey registration fails | Public URL must be HTTPS; RP ID must match the chosen hostname. Check bootstrap expiry and server time with `timedatectl status`. |
| HTTP 429 affects every client at once | Compare the container's inspected gateway with `MYTERM_RELAY_TRUSTED_PROXY_CIDRS`, including the `/32`. Confirm Cloudflare still sends `X-Forwarded-For`. Do not solve this with a broad trusted range. |
| One client receives HTTP 429 after repeated sign-in attempts | Wait for that client's rate limit to recover, then inspect relay logs and confirm the deployed version supports proxy-aware limits. |
| HTTP works but the terminal does not connect | Check WebSockets, app sign-in, Mac approval, and that the host stays awake. A 200 health response does not test the encrypted session. |
| Dev changes affect prod data | Stop and check Compose project names, env files, and bind-mount paths. They must differ. |

## Notifications are a separate deployment

This guide gets terminal access working. Push delivery requires the [shared push gateway](../Services/push-gateway/README.md), Apple APNs credentials, App Attest configuration, and a signed physical-device test. Ordinary relay operators do not need the app publisher's Apple provider key.

If you operate the companion distribution, the push gateway can use another hostname and local port on this tunnel. Its dev and prod instances need separate storage and matching Apple environments. Do not place an APNs key in the relay image or these environment files.

## References

- [Relay configuration and account recovery](../Services/relay/README.md)
- [Companion build, pairing, and notification setup](COMPANION.md)
- [Cloudflare dashboard tunnel setup](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)
- [Cloudflare package repository](https://pkg.cloudflare.com/)
- [Cloudflare HTTP request headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/)
- [Cloudflare Tunnel firewall requirements](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)
- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Compose network attributes](https://docs.docker.com/reference/compose-file/networks/)
