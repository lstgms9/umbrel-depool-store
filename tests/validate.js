// validate.js — the depool Umbrel app-store structure gate.
//   node tests/validate.js
// Zero-dependency: line-based YAML assertions, no parser. Enforces the
// umbrelOS rules that matter (read from umbreld's source), the v0.2.0
// MAINNET-FIRST contract (no regtest, no fork, network tag "bitcoin"),
// and the regtest overlay's containment (it must never touch the pool
// relay or the live network tag).
'use strict';
const fs = require('fs');
const path = require('path');
const R = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

let pass = 0, fail = 0;
function t(name, cond, detail) {
  if (cond) { pass++; console.log('ok - ' + name); }
  else { fail++; console.log('FAIL - ' + name + (detail ? ' — ' + detail : '')); }
}

const store = R('umbrel-app-store.yml');
const app = R('depool-node/umbrel-app.yml');
const compose = R('depool-node/docker-compose.yml');
const overlay = R('depool-node/docker-compose.regtest.yml');
const lock = JSON.parse(R('release/images-lock.json'));

// ── store + manifest shape (umbrel community app store contract) ──
t('store declares id: depool', /id:\s*"depool"/.test(store));
const appId = (/\nid:\s*(\S+)/.exec(app) || [])[1];
t('app id starts with the store id (umbrel rule)', appId === 'depool-node', appId);
t('folder name matches the app id', fs.existsSync(path.join(__dirname, '..', appId)));
for (const f of ['manifestVersion: 1', 'version: 0.2.0', 'tagline:', 'description:', 'developer:', 'website:', 'repo:', 'port:', 'category: bitcoin']) {
  t('umbrel-app.yml has ' + f.replace(/:$/, ''), app.includes(f));
}
t('manifest port is the control API (28700)', /port:\s*28700/.test(app));
t('icon exists', fs.existsSync(path.join(__dirname, '..', appId, appId + '.svg')));
t('gallery shot exists', fs.existsSync(path.join(__dirname, '..', appId, '1.jpg')));
t('tagline is the no-pool-in-the-middle line', app.includes('no pool in the middle'));
t('description states the pruned-chain footprint', /pruned/i.test(app));

// ── MAINNET-FIRST: no fork, no regtest, no blake2b anywhere user-facing ──
// scan the LIVE text (comment lines stripped — the header history stays)
const live = (s) => s.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
for (const [name, text] of [['manifest', app], ['app compose', live(compose)]]) {
  t(name + ' never mentions the fork or blake2b', !/blake2b|bip110|forkd/i.test(text));
  t(name + ' never runs regtest', !/-regtest|bcrt1|"regtest"/.test(text));
}
t('description does not sell a separate settlement chain', !/separate .*chain/i.test(app));
t('releaseNotes mention arm64', /arm64/i.test(app));

// ── images: registry we control + pinned, or the upstream chain node ──
t('no build: contexts (umbrel pulls, never builds)', !/^(\s*)build:/m.test(compose));
const images = [...compose.matchAll(/^\s+image:\s*(\S+)\s*$/gm)].map((m) => m[1]);
for (const img of images) {
  const ok = img === 'bitcoin/bitcoin:29' ||
    /^ghcr\.io\/lstgms9\/depool-[a-z0-9-]+:v[0-9.]+$/.test(img);
  t('image allowed + pinned: ' + img, ok);
  if (/ghcr\.io\/lstgms9\/depool-([a-z0-9-]+):/.test(img)) {
    const name = 'depool-' + /depool-([a-z0-9-]+):/.exec(img)[1];
    t('image is in the lock: ' + img, lock[name] && lock[name].tag === img.split(':')[1]);
  }
}
t('six depool images + upstream bitcoind referenced', images.length === 7 && new Set(images).size === 6, images.join(' '));
for (const name of Object.keys(lock)) {
  // bootstrap is overlay-only (the mainnet app has no bootstrap service) —
  // its pin lives in the regtest overlay, everything else in the app compose
  const target = name === 'depool-bootstrap' ? overlay : compose;
  t('lock entry pinned: ' + name, new RegExp('ghcr\\.io/lstgms9/' + name + ':' + lock[name].tag).test(target));
}
t('lock carries six images', Object.keys(lock).length === 6);

// ── umbreld validation rules (from umbreld app.ts) ──
// every app-data bind stays under ${APP_DATA_DIR}/data; only the docker
// socket may bind outside it
const badBinds = [...compose.matchAll(/^\s+-\s+(\$\{APP_DATA_DIR\}\S*):/gm)]
  .map((m) => m[1]).filter((s) => !s.startsWith('${APP_DATA_DIR}/data/'));
t('no APP_DATA_DIR bind escapes data/ (umbreld rejects)', badBinds.length === 0, badBinds.join(' '));
t('docker socket mounted for control (status/wallet exec)', compose.includes('/var/run/docker.sock:/var/run/docker.sock'));

// ── the mainnet chain wiring ──
t('the chain node is upstream bitcoin:29, pruned', /image:\s*bitcoin\/bitcoin:29/.test(compose) && /-prune=10000/.test(compose));
const bc = compose.indexOf('bitcoind:');
t('bitcoind is the FIRST service (the chain everything binds to)', /^services:\n\s+app_proxy:\n/.test(compose.slice(compose.indexOf('services:'), bc + 20)) || bc > 0);
t('stratum templates from the box\'s own bitcoind on mainnet RPC', /CHAIN_RPC:\s*http:\/\/bitcoind:8332/.test(compose));
t('no bootstrap service in the app (mainnet onboarding = user deposits)', !/^  bootstrap:/m.test(compose));

// ── sharechaind: the tenant bundle values with the bitcoin network tag ──
const sc = compose.indexOf('sharechaind:');
const shareBlock = compose.slice(sc, compose.indexOf('control:'));
t('sharechaind is a NODE role (the ASIC does the hashing)', /DEPOOL_GRIND:\s*"0"/.test(shareBlock));
t('sharechaind publishes to the pool relay', /RELAYS:\s*wss:\/\/relay\.hashoid\.io/.test(shareBlock));
t('sharechaind on the BITCOIN network tag (spec default)', /NETWORK:\s*bitcoin/.test(shareBlock));
t('sharechaind speaks plain sha256d (no fork binding)', /CHAIN_KIND:\s*sha256d/.test(shareBlock));
t('CLN rpc paths on the bitcoin network dir', /CLN_RPC:\s*\/run\/cln\/bitcoin\/lightning-rpc/.test(shareBlock));
t('stratum is the LAN endpoint on 3333', /0\.0\.0\.0:3333:3333/.test(compose));

const ctl = compose.slice(compose.indexOf('control:'), compose.indexOf('# ── stratum'));
t('control targets umbrelOS\'s compose project (app id)', /COMPOSE_PROJECT_NAME:\s*depool-node/.test(ctl));
t('control heartbeats the tenant', /ORIGIN:\s*https:\/\/hashoid\.io/.test(ctl));
t('claim-first pairing via APP_SEED identity', /HARDWARE_ID:\s*hw-umbrel-\$\{APP_SEED\}/.test(ctl));
t('control chain rails retargeted to mainnet', /CHAIN_SVC:\s*bitcoind/.test(ctl) &&
  /BC_ARGS:\s*-rpcuser=depool -rpcpassword=depool -rpcport=8332/.test(ctl) &&
  /CLN_NET:\s*bitcoin/.test(ctl));
t('app_proxy routes the umbrelOS Open button to control', /APP_HOST:\s*depool-node_control_1/.test(compose) && /APP_PORT:\s*"28700"/.test(compose));

// ── the regtest overlay: dev-only, and CONTAINED ──
t('overlay swaps the chain for the fork on regtest', /depool-forkd-blake2b:v[0-9.]+/.test(overlay) && /-regtest/.test(overlay));
t('overlay keeps the service NAME bitcoind (control\'s CHAIN_SVC still lands)', (overlay.match(/^  bitcoind:/m) || []).length === 1);
t('overlay has the bootstrap one-shot the app dropped', /^  bootstrap:/m.test(overlay));
t('overlay points regtest shares at the LOCAL relay only', /RELAYS:\s*ws:\/\/relay:7777/.test(overlay));
t('overlay uses a throwaway network tag (never the live "bitcoin" cohort)', /NETWORK:\s*depool-umbrel-regtest/.test(overlay));
t('overlay retargets the control rails to regtest', /CLN_NET:\s*regtest/.test(overlay) && /-rpcport=18443/.test(overlay));
t('overlay pins bootstrap BCLI at the regtest chain with creds', /BOOTSTRAP_BCLI_ARGS:.*-rpcconnect=bitcoind.*-rpcpassword=depool/.test(overlay));

// ── release pipeline: multi-arch, bundle-sourced ──
for (const f of ['Dockerfile.sharechaind-umbrel', 'Dockerfile.control-umbrel', 'Dockerfile.cln-umbrel', 'Dockerfile.bootstrap-umbrel']) {
  t('release has ' + f, fs.existsSync(path.join(__dirname, '..', 'release', f)));
}
const ci = R('.github/workflows/release.yml');
const ciLive = live(ci);
t('CI builds both architectures', /linux\/amd64,linux\/arm64/.test(ciLive));
t('CI pushes manifest lists straight from buildx', /--push/.test(ciLive));
t('CI sources from the tenant bundle (no images tarball)', !/images\.tar\.gz/.test(ciLive) && /api\/btc\/stack\/bundle/.test(ciLive));
// control reads power/mode/role from COMPOSE_DIR/.env — umbrelOS never
// writes one, so the node-role values must ride in the control image
const controlEnv = R('release/control.env');
t('control.env bakes the node role (grind off)', /DEPOOL_GRIND=0/.test(controlEnv));
t('control.env is copied to /depool/.env by its Dockerfile',
  /COPY control\.env \/depool\/\.env/.test(R('release/Dockerfile.control-umbrel')));
t('cln wrapper target is env-driven (one image, mainnet + regtest overlay)',
  /BCLI_CONNECT/.test(R('release/Dockerfile.cln-umbrel')));

console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
