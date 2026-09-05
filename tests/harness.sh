#!/bin/bash
# harness.sh — run the depool-node app compose on dev, simulating umbrelOS's
# compose conventions (no Umbrel box in the fleet):
#   - ONE compose file, project name = the app id (umbreld: --project-name $app)
#   - APP_DATA_DIR / APP_SEED / DEVICE_HOSTNAME exported like the legacy
#     app-script does (app-script:180,234)
#   - images pulled by pinned ghcr tag — here they are locally tagged by
#     SKIP_PUSH=1 build-images.sh (byte-identical bytes, no registry round-trip)
# Deltas, both mechanical and none of them touch the app file:
#   - host ports shifted (3333->13333, 28700->28701, 2085->12085): the LIVE
#     depool stack owns the real ports on this box
#   - ORIGIN -> dead loopback: a real heartbeat would register a fake rig on
#     the live hashoid tenant (pollution); control's unreachable-ORIGIN path
#     is the error branch it already handles
set -u
APP=depool-node
H=/home/damon/umbrel-harness
DATA=$H/app-data/$APP/data
SEED=$(python3 -c 'import random;print("".join(random.choice("0123456789abcdef") for _ in range(64)))')

rm -rf "$H"; mkdir -p "$DATA"
sed -e 's/0\.0\.0\.0:3333:3333/0.0.0.0:13333:3333/' \
    -e 's/127\.0\.0\.1:28700:28700/127.0.0.1:28701:28700/' \
    -e 's/127\.0\.0\.1:2085:7777/127.0.0.1:12085:7777/' \
    -e 's#ORIGIN: https://hashoid\.io#ORIGIN: http://127.0.0.1:9#' \
    -e '/^  app_proxy:/,/^      APP_PORT:/d' \
    ~/umbrel-depool-store/depool-node/docker-compose.yml > "$H/docker-compose.yml"
# app_proxy has no image line BY DESIGN: umbrelOS injects its gateway sidecar
# (and deletes the service from the runtime compose) — plain compose can't
# config it, so the harness copy drops it like umbreld does.

export APP_DATA_DIR=$DATA APP_SEED=$SEED DEVICE_HOSTNAME=umbrel APP_PASSWORD=x
DC="docker compose -p $APP -f $H/docker-compose.yml"

echo "[harness] config validation (umbrel rules run client-side too)"
$DC config >/dev/null || { echo "FAIL compose config"; exit 1; }

echo "[harness] up (project $APP — the umbrelOS convention)"
$DC up -d 2>&1 | tail -3

ok=0; fail=0
t() { if [ "$2" = "0" ]; then echo "ok - $1"; ok=$((ok+1)); else echo "FAIL - $1"; fail=$((fail+1)); fi; }

# 1. bootstrap: one-shot, must finish with BOOTSTRAP-OK (funding + channel).
# Poll the REAL condition — the log line — not the container state; a cold
# two-chain regtest can outrun a short ceiling (first run proved it).
BOOT=0
for i in $(seq 1 240); do
  $DC logs bootstrap 2>&1 | grep -q BOOTSTRAP-OK && BOOT=1 && break
  sleep 5
done
t "bootstrap says BOOTSTRAP-OK" "$((1 - BOOT))"
$DC ps -a --format '{{.Service}} {{.State}}' 2>/dev/null | grep -q '^bootstrap exited'; t "bootstrap exited (one-shot, not restarted)" $?

# 2. sharechaind minted its identity (the npub the heartbeat pairs with)
NPUB=""
for i in $(seq 1 60); do
  NPUB=$($DC exec -T sharechaind cat /data/miner.json 2>/dev/null | sed -n 's/.*"npub"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$NPUB" ] && break
  sleep 5
done
[ -n "$NPUB" ]; t "sharechaind minted its npub (${NPUB:0:12}...)" $?

# 3. control /status: the same JSON surface the node page drives
sleep 3
ST=$($DC exec -T control wget -qO- http://127.0.0.1:28700/status 2>/dev/null || curl -sf http://127.0.0.1:28701/status)
echo "$ST" | python3 -c 'import json,sys; d=json.load(sys.stdin); exit(0 if d.get("running") and d.get("role")=="node" and d.get("grinding") is False else 1)' \
  ; t "control /status: running=true, role=node, grinding=false" $?
echo "$ST" | grep -q '"height"'; t "control /status carries node facts (height)" $?

# 4. the ASIC-facing endpoint: stratum answers on the LAN port
printf '{"id":1,"method":"mining.subscribe","params":["harness"]}\n' | timeout 5 python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", 13333), timeout=4)
s.sendall(sys.stdin.buffer.read())
s.settimeout(4)
print(s.recv(4096).decode(errors="replace").splitlines()[0][:120])
' > /tmp/stratum-reply.txt 2>&1
grep -qi "mining\|notify\|set_difficulty\|{" /tmp/stratum-reply.txt; t "stratum answers on the shifted LAN port (13333)" $?
echo "  stratum: $(cat /tmp/stratum-reply.txt)"

# 5. wallet rail: control reaches CLN inside the project (compose exec + project name)
$DC exec -T control node -e '
const { execFile } = require("child_process");
execFile("docker", ["compose","--project-directory","/depool","-f","/depool/docker-compose.yml","exec","-T","cln-payee","lightning-cli","--network=regtest","--lightning-dir=/root/.lightning-payee","getinfo"], {env: {...process.env, COMPOSE_PROJECT_NAME: "depool-node"}, timeout: 20000}, (e, out) => {
  try { const j = JSON.parse(out.slice(out.indexOf("{"))); process.exit(j.id ? 0 : 1); }
  catch (err) { console.error(String(out||e)); process.exit(1); }
});' 2>/dev/null
t "control reaches cln-payee through the baked compose + project name" $?

echo "[harness] $ok passed, $fail failed"
$DC down -v >/dev/null 2>&1
# the data dir is root-owned (container users wrote it) — clean via a root container
docker run --rm -v "$H:/x" alpine rm -rf /x/app-data >/dev/null 2>&1
rm -rf "$H"
[ "$fail" = "0" ]
