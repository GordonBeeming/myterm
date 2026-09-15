#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: package_relay.sh VERSION OUTPUT_DIRECTORY}"
output="${2:?usage: package_relay.sh VERSION OUTPUT_DIRECTORY}"
architectures=(amd64 arm64)
if [[ -n "${3:-}" ]]; then
  case "$(uname -m):$3" in
    x86_64:amd64|aarch64:arm64|arm64:arm64) architectures=("$3") ;;
    *) echo 'A single architecture must match the native runner for smoke testing' >&2; exit 1 ;;
  esac
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo 'Version must be MAJOR.MINOR or MAJOR.MINOR.PATCH' >&2
  exit 1
fi
mkdir -p "$output"
output="$(cd "$output" && pwd)"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container=""
scratch="$(mktemp -d)"
cleanup() {
  if [[ -n "$container" ]]; then docker rm -f "$container" >/dev/null; fi
  rm -rf "$scratch"
}
trap cleanup EXIT

for arch in "${architectures[@]}"; do
  image="myterm-relay:${version}-linux-${arch}"
  archive="myterm-relay-${version}-linux-${arch}.docker.tar.gz"
  docker buildx build --platform "linux/$arch" --load \
    --tag "$image" "$root/Services/relay"
  test "$(docker image inspect "$image" --format '{{.Architecture}}')" = "$arch"
  docker save "$image" | gzip > "$output/$archive"
  gzip -t "$output/$archive"
  # Check the archive can be consumed by the command documented for operators.
  docker load --input "$output/$archive"

  case "$(uname -m):$arch" in
    x86_64:amd64|aarch64:arm64|arm64:arm64)
      container="$(docker run -d --read-only --tmpfs /tmp --tmpfs /data:uid=65532,gid=65532,mode=0700 \
        -p 127.0.0.1::8787 \
        -e MYTERM_RELAY_PUBLIC_URL=https://relay.example.com \
        -e MYTERM_RELAY_RP_ID=relay.example.com \
        -e MYTERM_RELAY_LISTEN=0.0.0.0:8787 \
        -e MYTERM_RELAY_DATABASE=/data/relay.sqlite3 "$image")"
      port="$(docker port "$container" 8787/tcp | cut -d: -f2)"
      ready=false
      for ((attempt=0; attempt<30; attempt++)); do
        if curl --fail --silent "http://127.0.0.1:$port/healthz" > /dev/null; then
          ready=true
          break
        fi
        sleep 1
      done
      if [[ "$ready" != true ]]; then
        docker logs "$container" >&2
        exit 1
      fi
      docker exec "$container" /app/myterm-relay bootstrap-owner --expires 1m > "$scratch/bootstrap"
      test -s "$scratch/bootstrap"
      docker rm -f "$container" > /dev/null
      container=""
      ;;
  esac
  (cd "$output" && shasum -a 256 "$archive" > "$archive.sha256")
done
