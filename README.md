# depool — Umbrel community app store

The depool node as a one-click Umbrel app. The whole UX is one line:

> **Umbrel → Settings → (∔) Add store → paste `https://github.com/lstgms9/umbrel-depool-store` → Install "Depool Node"**

Then:

1. Wait for the node's first sync — full validation of real Bitcoin on a
   pruned chain (~10GB kept, a few days on a Pi). The node page shows live
   height + peers while it works.
2. Point your ASIC at the Umbrel box's LAN address, **stratum port 3333**.
3. Open **hashoid.io → Mine** — the box shows up unclaimed; name it. It
   pairs through the exact same claim-first flow as a bare-metal install
   (`stack/install.sh`): the control sidecar heartbeats the tenant, the
   daemon mints its npub, payouts settle over Lightning.

## Mainnet-first (v0.2.0)

The app mines **real Bitcoin** — the spec reframe (2026-08-31): depool is a
payout-coordination protocol for any SHA-256 Bitcoin, mainnet-first; there
is no depool chain and no fork as product. Concretely:

- **One chain, not two.** `bitcoind` (upstream `bitcoin/bitcoin:29`,
  `-prune=10000`) is both the template source — stratum and sharechaind
  build jobs from THIS box's node via getblocktemplate (template
  sovereignty, spec §7.1) — and the Lightning settlement chain (CLN on the
  same node). The two-chain split (forkd + lnchain) belonged to the blake2b
  test ground; it is gone.
- **`NETWORK: bitcoin`.** The sharechain's network tag names the chain being
  mined (spec default). No `bip110-blake2b`, no `-regtest`, no fork language
  anywhere user-facing — `tests/validate.js` enforces that.
- **No bootstrap one-shot.** Nothing to fund on mainnet: the user deposits
  real sats through the node page's on-chain card (control `/onchain`) when
  they want the payout rail loaded.

## What the app wraps

`depool-node/docker-compose.yml` wraps the EXISTING stack —
`mod-btc/stack/docker-compose.yml` (+ overlays over time), the same service
definitions the live dev service stack runs — flattened, because umbrelOS
runs one compose file with no overlay mechanism. The deltas are only the
Umbrel bits:

| Delta | Why |
|---|---|
| images `ghcr.io/lstgms9/depool-*` (pinned) + upstream `bitcoin/bitcoin:29` | umbrelOS pulls, never builds. Multi-arch (amd64 + arm64) manifest lists |
| volumes → `${APP_DATA_DIR}/data/...` | umbrelOS validates app data lives under `APP_DATA_DIR/data`; uninstall/backup behave |
| `/modules` baked into depool-sharechaind | an Umbrel box has no platform checkout; CI assembles the SAME reduced tree the tenant bundle ships (`routes.js /stack/bundle`) |
| `HARDWARE_ID: hw-umbrel-${APP_SEED}` | umbrelOS exports `APP_SEED` into app compose — deterministic per install, so claim-first pairing works untouched |
| `COMPOSE_PROJECT_NAME: depool-node` in control | umbrelOS composes every app under `--project-name <app id>`; control's status/wallet are `docker compose ps/exec`, so the project name is what lands them on umbrelOS's own containers |
| `CHAIN_SVC/BC_ARGS/CLN_NET` in control | the chain rails are env-driven (mod-btc 38d38a9): mainnet values in the app compose, regtest defaults keep the dev stack unchanged |

## The regtest overlay (dev only)

`depool-node/docker-compose.regtest.yml` re-targets the SAME services at the
blake2b regtest fork (cheap blocks) + the bootstrap one-shot, so
`tests/harness.sh regtest` can prove the wrap's MECHANICS — funded channel,
share flow, BOLT12 payout — with the shipped file. It pins shares to the
LOCAL relay under a throwaway network tag; umbrelOS never sees this file and
the live `bitcoin` cohort is never touched.

## What is different on Umbrel (by design)

- **Start / stop / power belong to the umbrelOS UI.** Control's
  `/start`, `/stop` and `/power` still answer, but the app lifecycle is
  umbrelOS's — the node page's power card is informative; flip the app
  off in Umbrel to actually stop it.
- **No `build:` anywhere.** Everything arrives as pinned registry images.
- **Stratum is the only LAN-exposed port** (`0.0.0.0:3333`). Relay stays
  loopback; control stays loopback (28700) exactly like bare metal.

## Releasing new images

**CI is the pipeline** (the dev box's fine-grained PAT cannot write ghcr
packages; the workflow's GITHUB_TOKEN can): GitHub → lstgms9/umbrel-depool-store
→ Actions → **release** → Run workflow with the version. Since v0.2.0 there
is no images tarball dependency — buildx builds `linux/amd64` **and**
`linux/arm64` FROM SOURCE (qemu emulates the Pi; strfry's arm64 compile is
the slow step), pushes manifest lists, rewrites the compose pins and commits
`images-lock.json` (manifest-list digests). Inputs: the public tenant bundle
(`ORIGIN/api/btc/stack/bundle`) + this repo's `release/` Dockerfiles.
`depool-bootstrap` is built but is overlay-only (not in the app compose);
`bitcoin/bitcoin:29` is referenced upstream directly (already multi-arch).

**Visibility:** packages pushed by the workflow came out **public** —
verified with an anonymous manifest pull (v0.1.0, 2026-09-05). If a future
release lands private, flip it at github.com/lstgms9?tab=packages →
Package settings → Change visibility.

`release/build-images.sh` (v0.1.0 dev-box fallback, amd64 tarball path) is
SUPERSEDED by the workflow; it still documents the module-tree assembly.

## Layout

```
umbrel-app-store.yml      store manifest (id: depool)
depool-node/              the app (id must start with the store id)
  umbrel-app.yml          listing shown in the umbrelOS UI
  docker-compose.yml      the wrap — mainnet, see above
  docker-compose.regtest.yml  dev overlay (harness only; umbrelOS never sees it)
  depool-node.svg         app icon
  1.jpg                   gallery shot
release/                  image pipeline (runs in CI)
  Dockerfile.cln-umbrel       CLN + env-driven bitcoin-cli wrapper
  Dockerfile.sharechaind-umbrel  node + ws + daemon + baked modules tree
  Dockerfile.control-umbrel   control + baked app compose + control.env
  Dockerfile.bootstrap-umbrel the regtest one-shot (overlay only)
  control.env             node-role values baked to /depool/.env
  images-lock.json        pushed manifest-list digests, the pin source of truth
tests/validate.js         structure gate: node tests/validate.js
tests/harness.sh          dev harness: mainnet leg (default) + regtest leg
```

## Verified how

No Umbrel box in the fleet, so the harness is **dev (Debian) + Docker
simulating umbrelOS's compose conventions** (`tests/harness.sh`): project
name = the app id, `APP_DATA_DIR`/`APP_SEED`/`DEVICE_HOSTNAME` exported as
umbreld's app-script does, images by pinned ghcr tag, one compose file.

- **mainnet leg** (the shipped app, as-is): real mainnet IBD (height grows,
  real peers), control `/status` `running=true role=node grinding=false`
  with live node facts, **stratum answers `mining.subscribe`** on the LAN
  port, control's compose-exec reaches cln-payee on the bitcoin network dir.
- **regtest leg** (same services + overlay): bootstrap funds the payer +
  opens the channel (`BOOTSTRAP-OK`, exits), sharechaind mints its npub on
  the throwaway tag, wallet rail reaches cln-payee through the baked
  compose + project name.

umbreld's own validation rules (data under `APP_DATA_DIR/data`, `APP_SEED` +
`DEVICE_HOSTNAME` injection, `--project-name <app id>`) were read from
umbreld's source and are enforced by `tests/validate.js`. Findings the
harness caught: control reads power/role from `COMPOSE_DIR/.env`, which
umbrelOS never materializes — the node-role values are baked into the
control image (`release/control.env`); and CLN's bcli check needs a
bitcoin-cli wrapper whose target now follows `BCLI_*` env.
Not yet exercised: umbrelOS's app-store installer itself (needs a real
umbrelOS box or VM).
