# depool — Umbrel community app store

The depool node as a one-click Umbrel app. The whole UX is one line:

> **Umbrel → Settings → (∔) Add store → paste `https://github.com/lstgms9/umbrel-depool-store` → Install "Depool Node"**

Then:

1. Point your ASIC at the Umbrel box's LAN address, **stratum port 3333**.
2. Open **hashoid.io → Mine** — the box shows up unclaimed; name it. It
   pairs through the exact same claim-first flow as a bare-metal install
   (`stack/install.sh`): the control sidecar heartbeats the tenant, the
   daemon mints its npub, payouts settle over Lightning.

## What the app wraps

`depool-node/docker-compose.yml` wraps the EXISTING stack —
`mod-btc/stack/docker-compose.yml` + `docker-compose.blake2b.yml` (the same
two files the live dev service stack runs) — flattened, because umbrelOS runs
one compose file with no overlay mechanism. Services, commands and env are
verbatim from that merge. The only deltas are the Umbrel bits:

| Delta | Why |
|---|---|
| images `ghcr.io/lstgms9/depool-*` (pinned) | umbrelOS pulls, never builds. Same bytes `stack/build-images.sh` produces, pushed by `release/build-images.sh` |
| volumes → `${APP_DATA_DIR}/data/...` | umbrelOS validates app data lives under `APP_DATA_DIR/data`; uninstall/backup behave |
| `/modules` + `/mod-btc` baked into derived images | an Umbrel box has no platform checkout; `release/build-images.sh` assembles the SAME reduced tree the tenant bundle ships (`routes.js /stack/bundle`) |
| `HARDWARE_ID: hw-umbrel-${APP_SEED}` | umbrelOS exports `APP_SEED` into app compose — deterministic per install, so claim-first pairing works untouched |
| `COMPOSE_PROJECT_NAME: depool-node` in control | umbrelOS composes every app under `--project-name <app id>`; control's status/wallet are `docker compose ps/exec`, so the project name is what lands them on umbrelOS's own containers |

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
→ Actions → **release** → Run workflow with the version. Every input is a
public artifact the tenant already serves (the same images tarball + bundle
`install.sh` uses) plus the stripped Knots binaries committed under
`release/forkd-bin/`. The workflow pushes the seven images, rewrites the
compose pins and commits `images-lock.json`.

**ONE-TIME after the first run:** flip the seven ghcr packages public —
github.com/lstgms9?tab=packages → each package → Package settings →
Change visibility → Public. umbrelOS pulls anonymously; private packages
403 for users. Later releases keep the visibility.

Dev-box fallback (works, needs a packages-scoped token):
`release/build-images.sh v0.1.1`.

 amd64 only — the stack's image tarball is amd64-only today; a Pi/ARM Umbrel
 box is unsupported until the stack ships arm tarballs.

## Layout

```
umbrel-app-store.yml      store manifest (id: depool)
depool-node/              the app (id must start with the store id)
  umbrel-app.yml          listing shown in the umbrelOS UI
  docker-compose.yml      the wrap — see above
  depool-node.svg         app icon
  1.jpg                   gallery shot
release/                  image pipeline (runs on dev)
  build-images.sh         retag → bake derived → push → pin
  Dockerfile.*            the three derived images
  images-lock.json        pushed digests, the pin source of truth
tests/validate.js         structure gate: node tests/validate.js
```

## Verified how

No Umbrel box in the fleet, so the harness is **dev (Debian) + Docker
simulating umbrelOS's compose conventions** (`tests/harness.sh`): project
name = the app id, `APP_DATA_DIR`/`APP_SEED`/`DEVICE_HOSTNAME` exported as
umbrelOS's app-script does, images by pinned ghcr tag, one compose file.
Result on a cold run: **7/7** — bootstrap funds the payer + opens the
channel (`BOOTSTRAP-OK`, exits), sharechaind mints its npub, control
`/status` reports `running=true role=node grinding=false` with live node
facts, **stratum answers a real `mining.subscribe`** on the LAN port, and
control's compose-exec reaches cln-payee through the baked compose +
project name (the wallet rail). umbreld's own validation rules (data under
`APP_DATA_DIR/data`, `APP_SEED` + `DEVICE_HOSTNAME` injection,
`--project-name <app id>`) were read from umbreld's source and are enforced
by `tests/validate.js`. One finding the harness caught: control reads
power/role from `COMPOSE_DIR/.env`, which umbrelOS never materializes — the
node-role values are now baked into the control image (`release/control.env`).
Not yet exercised: umbrelOS's app-store installer itself (needs a real
umbrelOS box or VM).
