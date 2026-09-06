#!/bin/bash
# harness.sh — run the depool-node app compose on dev, simulating umbrelOS's
# compose conventions (no Umbrel box in the fleet):
#   - ONE compose file (mainnet leg), project name = the app id
#   - APP_DATA_DIR / APP_SEED / DEVICE_HOSTNAME exported like the legacy
#     app-script does (app-script:180,234)
#   - images pulled by pinned ghcr tag (LOCAL=1 to use locally tagged ones)
#
# TWO LEGS:
#   tests/harness.sh            MAINNET (default) — the shipped app, as-is:
#                               the chain syncs REAL mainnet, so the run
#                               proves boot + IBD + control/stratum/CLN
#                               rails, not blocks (those take days).
#   tests/harness.sh regtest    the app compose + docker-compose.regtest.yml
#                               — the same services on the blake2b regtest
#                               fork, where blocks are cheap: full mechanics
#                               (bootstrap funds, channel opens, shares flow).
#
# Deltas, all mechanical, none touch the app file's wiring:
#   - host ports shifted (3333->13333, 28700->28701, 2085->12085): the LIVE
#     depool stack owns the real ports on this box
#   - ORIGIN -> dead loopback: a real heartbeat would register a fake rig on
#     the live hashoid tenant (pollution); control's unreachable-ORIGIN path
#     is the error branch it already handles
#   - app_proxy stripped: umbrelOS injects its gateway sidecar and deletes
#     the service from the runtime compose; plain compose rejects it
set -u
APP=depool-node
H=/home/damon/umbrel-harness
SRC=/home/damon/platform/modules/umbrel-depool-store
DATA=$H/app-data/$APP/data
SEED=$(python3 -c 'import random;print("".join(random.choice("0123456789abcdef") for _ in range(64)))')
LEG=${1:-mainnet}
FILES="$SRC/depool-node/docker-compose.yml"
[ "$LEG" = regtest ] && FILES="$SRC/depool-node/docker-compose.yml $SRC/depool-node/docker-compose.regtest.yml"

rm -rf "$H" 2>/dev/null || true
# a previous leg's containers wrote root-owned files — clean as root
docker run --rm -v "$(dirname "$H"):/x" alpine rm -rf "/x/$(basename "$H")" >/dev/null 2>&1
mkdir -p "$DATA"
for f in $FILES; do
  sed -e 's/0\.0\.0\.0:3333:3333/0.0.0.0:13333:3333/' \
      -e 's/127\.0\.0\.1:28700:28700/127.0.0.1:28701:28700/' \
      -e 's/127\.0\.0\.1:2085:7777/127.0.0.1:12085:7777/' \
      -e 's#ORIGIN: https://hashoid\.io#ORIGIN: http://127.0.0.1:9#' \
      -e '/^  app_proxy:/,/^      APP_PORT:/d' \
      "$f" > "$H/$(basename "$f")"
done
export APP_DATA_DIR=$DATA APP_SEED=$SEED DEVICE_HOSTNAME=umbrel APP_PASSWORD=x
# -f ORDER MATTERS: later files override earlier ones. The glob would sort
# docker-compose.regtest.yml BEFORE docker-compose.yml (r < y), so the base
# file silently overrode the overlay — bitcoind came up as mainnet and the
# regtest sharechaind values were one failed depends_on away from the live
# relay. Pass the files in $FILES order, base first.
DC="docker compose -p $APP $(for f in $FILES; do echo -n "-f $H/$(basename "$f") "; done)"

[ "${LOCAL:-0}" = 1 ] || { echo "[harness] pulling the pinned images"; $DC pull >/dev/null 2>&1 || true; }

echo "[harness] config validation ($LEG leg)"
$DC config >/dev/null || { echo "FAIL compose config"; exit 1; }
if [ "$LEG" = regtest ]; then
  CFG=$($DC config 2>/dev/null) || { echo "FAIL compose config"; exit 1; }
  # containment: the overlay must be ONE stock sha256d chain on regtest — no
  # fork anywhere (stock CLN can't parse fork v2 blocks), and the sharechain
  # values MUST be the throwaway tag + local relay, never the live cohort
  echo "$CFG" | grep -qi 'blake2b\|forkd' \
    && { echo "FAIL overlay merge: fork/blake2b leaked into the regtest leg"; exit 1; }
  echo "$CFG" | grep -q 'NETWORK: depool-umbrel-regtest' \
    || { echo "FAIL overlay merge: throwaway network tag missing"; exit 1; }
  echo "$CFG" | grep -q 'RELAYS: ws://relay:7777' \
    || { echo "FAIL overlay merge: shares not pinned to the local relay"; exit 1; }
  echo "$CFG" | grep -q 'CHAIN_KIND: sha256d' \
    || { echo "FAIL overlay merge: CHAIN_KIND must stay sha256d"; exit 1; }
fi

echo "[harness] up (project $APP — the umbrelOS convention)"
$DC up -d 2>&1 | tail -3

ok=0; fail=0
t() { if [ "$2" = "0" ]; then echo "ok - $1"; ok=$((ok+1)); else echo "FAIL - $1"; fail=$((fail+1)); fi; }

# the control JSON surface (the node page drives the same one)
ctlStatus() { curl -sf http://127.0.0.1:28701/status; }

if [ "$LEG" = mainnet ]; then
  # 1. the chain really is syncing REAL mainnet: block count grows and it
  #    finds mainnet peers. Two samples, growth required. Headers-first IBD
  #    sits on height 0 for minutes before the first block lands — poll
  #    patiently for the first nonzero sample, then take a second one.
  B1=""
  for i in $(seq 1 180); do
    B1=$($DC exec -T bitcoind bitcoin-cli -rpcuser=depool -rpcpassword=depool -rpcport=8332 getblockcount 2>/dev/null | tr -d "\r")
    [ -n "$B1" ] && [ "$B1" -gt 0 ] 2>/dev/null && break; sleep 5
  done
  sleep 60
  B2=$($DC exec -T bitcoind bitcoin-cli -rpcuser=depool -rpcpassword=depool -rpcport=8332 getblockcount 2>/dev/null | tr -d "\r")
  PEERS=$($DC exec -T bitcoind bitcoin-cli -rpcuser=depool -rpcpassword=depool -rpcport=8332 getconnectioncount 2>/dev/null | tr -d "\r")
  if [ -n "$B1" ] && [ -n "$B2" ] && [ "$B2" -gt "$B1" ] && [ "${PEERS:-0}" -ge 1 ]; then
    t "bitcoind syncs REAL mainnet (height $B1 -> $B2, $PEERS peers)" 0
  else
    t "bitcoind syncs REAL mainnet (height '$B1' -> '$B2', peers '${PEERS:-?}')" 1
  fi

  # 2. control /status: node role + live node facts from the MAINNET rails
  ST=""
  for i in $(seq 1 60); do
    ST=$(ctlStatus) && echo "$ST" | grep -q '"running":true' && break; sleep 5
  done
  echo "$ST" | python3 -c 'import json,sys; d=json.load(sys.stdin); exit(0 if d.get("running") and d.get("role")=="node" and d.get("grinding") is False else 1)' \
    ; t "control /status: running=true, role=node, grinding=false" $?
  echo "$ST" | python3 -c 'import json,sys; d=json.load(sys.stdin); n=d.get("node") or {}; import sys as s; s.exit(0 if n.get("chainOk") and isinstance(n.get("height"), int) and n["height"]>0 else 1)' \
    ; t "control node facts: chainOk + mainnet height > 0 ($B2)" $?

  # 3. the ASIC-facing endpoint: stratum answers on the LAN port (template
  #    jobs need the chain synced — the PORT and protocol answer now)
  printf '{"id":1,"method":"mining.subscribe","params":["harness"]}\n' | timeout 5 python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", 13333), timeout=4)
s.sendall(sys.stdin.buffer.read())
s.settimeout(4)
print(s.recv(4096).decode(errors="replace").splitlines()[0][:120])
' > /tmp/stratum-reply.txt 2>&1
  grep -qi "mining\|notify\|set_difficulty\|{" /tmp/stratum-reply.txt; t "stratum answers on the shifted LAN port (13333)" $?
  echo "  stratum: $(cat /tmp/stratum-reply.txt)"

  # 4. wallet rails on mainnet: control reaches CLN through the baked compose
  #    + project name (CLN may still be waiting out the chain sync — the rail
  #    is what must connect)
  RAIL=0
  for i in $(seq 1 60); do
    if $DC exec -T control node -e '
const { execFile } = require("child_process");
execFile("docker", ["compose","--project-directory","/depool","-f","/depool/docker-compose.yml","exec","-T","cln-payee","lightning-cli","--network=bitcoin","--lightning-dir=/root/.lightning-payee","getinfo"], {env: {...process.env, COMPOSE_PROJECT_NAME: "depool-node"}, timeout: 20000}, (e, out) => {
  try { const j = JSON.parse(out.slice(out.indexOf("{"))); process.exit(j.id ? 0 : 1); }
  catch (err) { process.exit(1); }
});' 2>/dev/null; then RAIL=1; break; fi
    sleep 5
  done
  t "control reaches cln-payee on the bitcoin network (baked compose + project name)" "$((1 - RAIL))"
else
  # regtest leg: the full v0.1.0 mechanics, on the SAME service definitions
  # 1. bootstrap: one-shot, must finish with BOOTSTRAP-OK (funding + channel)
  BOOT=0
  for i in $(seq 1 240); do
    $DC logs bootstrap 2>&1 | grep -q BOOTSTRAP-OK && BOOT=1 && break
    sleep 5
  done
  t "bootstrap says BOOTSTRAP-OK" "$((1 - BOOT))"
  $DC ps -a --format '{{.Service}} {{.State}}' 2>/dev/null | grep -q '^bootstrap exited'; t "bootstrap exited (one-shot, not restarted)" $?

  # 2. sharechaind minted its identity, on the THROWAWAY network tag
  NPUB=""
  for i in $(seq 1 60); do
    NPUB=$($DC exec -T sharechaind cat /data/miner.json 2>/dev/null | sed -n 's/.*"npub"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$NPUB" ] && break
    sleep 5
  done
  [ -n "$NPUB" ]; t "sharechaind minted its npub (${NPUB:0:12}...)" $?
  # the network tag rides on every published bead (["network", …]) — the
  # daemon never prints it, so assert the RUNNING container carries the
  # throwaway tag (never the live "bitcoin" cohort)
  TAG=$($DC exec -T sharechaind printenv NETWORK 2>/dev/null | tr -d "\r")
  [ "$TAG" = "depool-umbrel-regtest" ]; t "shares stay on the throwaway network tag ($TAG)" $?

  # 3. control /status
  sleep 3
  ST=$(ctlStatus)
  echo "$ST" | python3 -c 'import json,sys; d=json.load(sys.stdin); exit(0 if d.get("running") and d.get("role")=="node" and d.get("grinding") is False else 1)' \
    ; t "control /status: running=true, role=node, grinding=false" $?
  echo "$ST" | grep -q '"height"'; t "control /status carries node facts (height)" $?

  # 4. stratum on the LAN port
  printf '{"id":1,"method":"mining.subscribe","params":["harness"]}\n' | timeout 5 python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", 13333), timeout=4)
s.sendall(sys.stdin.buffer.read())
s.settimeout(4)
print(s.recv(4096).decode(errors="replace").splitlines()[0][:120])
' > /tmp/stratum-reply.txt 2>&1
  grep -qi "mining\|notify\|set_difficulty\|{" /tmp/stratum-reply.txt; t "stratum answers on the shifted LAN port (13333)" $?
  echo "  stratum: $(cat /tmp/stratum-reply.txt)"

  # 5. wallet rail through the baked compose
  $DC exec -T control node -e '
const { execFile } = require("child_process");
execFile("docker", ["compose","--project-directory","/depool","-f","/depool/docker-compose.yml","exec","-T","cln-payee","lightning-cli","--network=regtest","--lightning-dir=/root/.lightning-payee","getinfo"], {env: {...process.env, COMPOSE_PROJECT_NAME: "depool-node"}, timeout: 20000}, (e, out) => {
  try { const j = JSON.parse(out.slice(out.indexOf("{"))); process.exit(j.id ? 0 : 1); }
  catch (err) { console.error(String(out||e)); process.exit(1); }
});' 2>/dev/null
  t "control reaches cln-payee through the baked compose + project name" $?
fi

echo "[harness] $LEG leg: $ok passed, $fail failed"
[ "${SKIP_DOWN:-0}" = 1 ] || $DC down -v >/dev/null 2>&1
# the data dir is root-owned (container users wrote it) — clean via a root container
docker run --rm -v "$H:/x" alpine rm -rf /x/app-data >/dev/null 2>&1
rm -rf "$H"
[ "$fail" = "0" ]
