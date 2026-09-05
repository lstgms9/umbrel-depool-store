// validate.js — the depool Umbrel app-store structure gate.
//   node tests/validate.js
// Zero-dependency: line-based YAML assertions, no parser. Enforces the
// umbrelOS rules that matter (read from umbreld's source) plus the wrap
// contract against mod-btc/stack — so a drift on either side fails here.
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
const lock = JSON.parse(R('release/images-lock.json'));

// ── store + manifest shape (umbrel community app store contract) ──
t('store declares id: depool', /id:\s*"depool"/.test(store));
const appId = (/\nid:\s*(\S+)/.exec(app) || [])[1];
t('app id starts with the store id (umbrel rule)', appId === 'depool-node', appId);
t('folder name matches the app id', fs.existsSync(path.join(__dirname, '..', appId)));
for (const f of ['manifestVersion: 1', 'version:', 'tagline:', 'description:', 'developer:', 'website:', 'repo:', 'port:', 'category: bitcoin']) {
  t('umbrel-app.yml has ' + f.replace(/:$/, ''), app.includes(f));
}
t('manifest port is the control API (28700)', /port:\s*28700/.test(app));
t('icon exists', fs.existsSync(path.join(__dirname, '..', appId, appId + '.svg')));
t('gallery shot exists', fs.existsSync(path.join(__dirname, '..', appId, '1.jpg')));
t('tagline is the no-pool-in-the-middle line', app.includes('no pool in the middle'));
t('description states the pruned-chain footprint', /pruned chain/i.test(app));

// ── images: registry we control + pinned, or public — NEVER a build ──
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
t('all seven depool images referenced', new Set(images).size === 8, images.join(' ')); // 7 + bitcoin:29
for (const name of Object.keys(lock)) {
  t('lock entry pinned: ' + name, new RegExp('ghcr\\.io/lstgms9/' + name + ':' + lock[name].tag).test(compose));
}

// ── umbreld validation rules (from umbreld app.ts) ──
// every app-data bind stays under ${APP_DATA_DIR}/data; only the docker
// socket may bind outside it
const badBinds = [...compose.matchAll(/^\s+-\s+(\$\{APP_DATA_DIR\}\S*):/gm)]
  .map((m) => m[1]).filter((s) => !s.startsWith('${APP_DATA_DIR}/data/'));
t('no APP_DATA_DIR bind escapes data/ (umbreld rejects)', badBinds.length === 0, badBinds.join(' '));
t('docker socket mounted for control (status/wallet exec)', compose.includes('/var/run/docker.sock:/var/run/docker.sock'));

// ── the wrap contract: same env the tenant bundle gives a customer box ──
const sc = compose.indexOf('sharechaind:');
const shareBlock = compose.slice(sc, compose.indexOf('control:'));
t('sharechaind is a NODE role (the ASIC does the hashing)', /DEPOOL_GRIND:\s*"0"/.test(shareBlock));
t('sharechaind publishes to the pool relay', /RELAYS:\s*wss:\/\/relay\.hashoid\.io/.test(shareBlock));
t('sharechaind on the live network', /NETWORK:\s*bip110-blake2b/.test(shareBlock));
t('sharechaind mines the blake2b fork', /CHAIN_KIND:\s*blake2b/.test(shareBlock));
t('stratum is the LAN endpoint on 3333', /0\.0\.0\.0:3333:3333/.test(compose));

const ctl = compose.slice(compose.indexOf('control:'), compose.indexOf('# ── P4 stratum'));
t('control targets umbrelOS\'s compose project (app id)', /COMPOSE_PROJECT_NAME:\s*depool-node/.test(ctl));
t('control heartbeats the tenant', /ORIGIN:\s*https:\/\/hashoid\.io/.test(ctl));
t('claim-first pairing via APP_SEED identity', /HARDWARE_ID:\s*hw-umbrel-\$\{APP_SEED\}/.test(ctl));
t('app_proxy routes the umbrelOS Open button to control', /APP_HOST:\s*depool-node_control_1/.test(compose) && /APP_PORT:\s*"28700"/.test(compose));

// ── derived-image pipeline present (Umbrel forces these three layers) ──
for (const f of ['Dockerfile.sharechaind-umbrel', 'Dockerfile.control-umbrel', 'Dockerfile.bootstrap-umbrel']) {
  t('release has ' + f, fs.existsSync(path.join(__dirname, '..', 'release', f)));
}
t('release script pushes + pins', /images-lock\.json/.test(R('release/build-images.sh')));

console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
