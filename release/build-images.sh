#!/bin/sh
# build-images.sh — push the depool stack images for the Umbrel app store.
# Runs on DEV (Docker + the platform checkout + ghcr.io login live there).
#
#   ./build-images.sh v0.1.0
#
# 1. retags the dev stack's built images (docker-compose project depool-stack
#    + depool-forkd-blake2b) to ghcr.io/lstgms9/depool-*:<version> and pushes
# 2. bakes the three derived Umbrel images (see Dockerfile.*-umbrel) from
#    those same bytes and pushes them
# 3. rewrites the version pins in ../depool-node/docker-compose.yml and
#    writes images-lock.json (digests — the gate test's pin source of truth)
#
# Everything derives from ONE version argument. No Dockerfiles are invented
# here beyond the three layers Umbrel forces (no checkout to mount).
set -eu
VER=${1:?usage: build-images.sh <version>}
STORE=$(cd "$(dirname "$0")/.." && pwd)
MODS=${MODULES_DIR:-/home/damon/platform/modules}
BUILD=$STORE/release/build
GH=ghcr.io/lstgms9
SRC=$MODS/mod-btc/stack

command -v docker >/dev/null || { echo "docker missing"; exit 1; }
[ -f "$SRC/docker-compose.yml" ] || { echo "stack checkout missing at $SRC"; exit 1; }

# ── 1. assemble the reduced modules tree — byte-identical to what the
#      tenant bundle ships (mod-btc/routes.js GET /stack/bundle) ──
rm -rf "$BUILD"; mkdir -p "$BUILD/modules/mod-btc/lib" "$BUILD/modules/mod-btc/sim" \
  "$BUILD/modules/mod-chat/lib" "$BUILD/modules/mod-chat/public/nostr" \
  "$BUILD/modules/mod-chat/public/vendor" "$BUILD/stack"
cp "$MODS/mod-btc/lib/sharechain.js"        "$BUILD/modules/mod-btc/lib/"
cp "$MODS/mod-btc/sim/frozen-params.json"   "$BUILD/modules/mod-btc/sim/"
cp "$MODS/mod-chat/lib/nostrshare.js" "$MODS/mod-chat/lib/resolve-dep.js" "$BUILD/modules/mod-chat/lib/"
for f in "$MODS/mod-chat/public/nostr/"*.js; do cp "$f" "$BUILD/modules/mod-chat/public/nostr/"; done
[ -f "$MODS/mod-chat/public/nostr/package.json" ] && cp "$MODS/mod-chat/public/nostr/package.json" "$BUILD/modules/mod-chat/public/nostr/"
cp -r "$MODS/mod-chat/public/vendor/noble"  "$BUILD/modules/mod-chat/public/vendor/"
cp "$STORE/depool-node/docker-compose.yml"  "$BUILD/docker-compose.yml"
cp "$SRC/bootstrap.sh"                      "$BUILD/stack/"

# ── 2. retag + push the four direct images ──
retag() { docker tag "$1" "$GH/$2:$VER" && docker push "$GH/$2:$VER" >/dev/null && echo "pushed $GH/$2:$VER"; }
retag depool-forkd-blake2b:latest     depool-forkd-blake2b
retag depool-stack-cln-payer:latest   depool-cln
retag depool-stack-relay:latest       depool-relay
retag depool-stack-stratum:latest     depool-stratum

# ── 3. bake + push the three derived images ──
bake() { # <dockerfile> <base> <name>
  docker build --build-arg BASE="$2" -f "$STORE/release/Dockerfile.$1" -t "$GH/$3:$VER" "$BUILD" >/dev/null
  docker push "$GH/$3:$VER" >/dev/null && echo "pushed $GH/$3:$VER"
}
bake sharechaind-umbrel depool-stack-sharechaind:latest depool-sharechaind
bake control-umbrel     depool-stack-control:latest     depool-control
bake bootstrap-umbrel   depool-stack-cln-payer:latest   depool-bootstrap

# ── 4. pin: compose version pins + images-lock.json (digests) ──
for svc in depool-forkd-blake2b depool-cln depool-relay depool-stratum depool-sharechaind depool-control depool-bootstrap; do
  sed -i "s#ghcr.io/lstgms9/$svc:v[0-9.]*#ghcr.io/lstgms9/$svc:$VER#g" "$STORE/depool-node/docker-compose.yml"
done
{
  echo '{'
  sep=""
  for svc in depool-forkd-blake2b depool-cln depool-relay depool-stratum depool-sharechaind depool-control depool-bootstrap; do
    d=$(docker inspect --format '{{index .RepoDigests 0}}' "$GH/$svc:$VER" 2>/dev/null | sed 's/.*@//' || echo '')
    [ -n "$sep" ] && echo "$sep"; sep=","
    printf ' "%s": {"tag": "%s", "digest": "%s"}' "$svc" "$VER" "$d"
  done
  echo ''
  echo '}'
} > "$STORE/release/images-lock.json"
echo "done — bump version: in depool-node/umbrel-app.yml to $VER and commit both"
