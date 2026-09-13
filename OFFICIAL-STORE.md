# The official Umbrel App Store route — plan, gates, evidence

Status 2026-09-13: **not submitted.** Damon approves every outward step; nothing is
sent to `getumbrel/umbrel-apps` until he says so. This doc is the plan and the
record of what we measured, so the next person starts here.

## The bar, from their own repo

Source: `getumbrel/umbrel-apps` — `AGENTS.md`, `README.md` ("App Store Standard"),
and the repo-local skills `.claude/skills/umbrel-{develop,package,test,update}-app`.
Read those before touching the package; they, not this file, are canonical.

- **Browser first.** The app must open to a web UI, setup flow, login page, or
  status page: "with no SSH, CLI access, log scraping, or manual file edits".
- **Multi-arch images**, publicly pullable without credentials, every image
  pinned `registry/repo:tag@sha256:<manifest-list digest>`.
- **Persistence** in bind mounts under `${APP_DATA_DIR}/data/...`, every
  host-side source directory committed (`.gitkeep` when empty).
- **No host Docker socket**, no `privileged`, no broad host mounts — "host
  Docker socket access is effectively host-root access".

## What their linter says about our package today

Run the real thing (a shallow clone of `getumbrel/umbrel-apps`, then):

```sh
npm install
npm run lint:apps -- depool-node            # --check-images once v0.2.2+ is pushed
```

Measured 2026-09-13 against our `depool-node/`: **24 errors, 7 warnings**.

| class | n | what it wants |
|---|---|---|
| `persistence.missing_source` | 11 | commit `data/<path>/.gitkeep` for every `${APP_DATA_DIR}/data/...` bind-mount source |
| `image.pinned` | 7 | `tag@sha256:<digest>` on all seven images (we hold six in `release/images-lock.json`; `bitcoin/bitcoin:29` needs one too) |
| `manifest.required` | 2 | add `dependencies` (use `[]` — we ship our own node) and `path` |
| `manifest.path` | 1 | `path: ""` |
| `access.docker_socket` | 1 | **control mounts `/var/run/docker.sock`** — forbidden |
| `ports.app_proxy` | 1 | control must not publish the manifest port with raw `ports:` |
| `ports.unique` | 1 | stratum's host port 3333 collides with `bleskomat-server` — pick a free one |
| `service.restart` (warn) | 7 | use `restart: on-failure` unless a service really needs otherwise |

The one that is real engineering is the **docker socket**: control currently gets
its status and wallet facts by shelling `docker compose ps/exec`. Store-ready
means getting them from the services themselves — bitcoind JSON-RPC, CLN's own
unix socket (already mounted as a volume), the daemon's status file, the relay's
port — and losing the container-restart power path (or moving it in-process).
That work is the v0.2.3 "store-ready" pass.

## The acceptance loop (their `umbrel-test-app` skill)

**Raw `docker compose up` is explicitly listed under "Do Not Accept As Proof"** —
our `tests/harness.sh` proves the mechanics and the regtest leg, and it never
counts as Umbrel verification. Accepted environments are a real Umbrel device or
a local umbrelOS test environment:

- privileged umbrelOS container:
  `docker run --privileged -it --network host --volume umbrelos-test:/data ghcr.io/getumbrel/umbrelos:<version> /sbin/init`
- `umbrel-dev` (script in `getumbrel/umbrel`; `npm run dev` start/logs/shell/client;
  dev instance at `umbrel-dev.local`)

The loop, in order:

1. `npm run lint:apps -- depool-node --check-images`
2. install the package into the test environment's app-store source path
3. drive install / update / restart through the UI or the `umbreld` client tRPC
4. verify through the **app_proxy route**, not a raw internal port
5. prove a restart keeps state
6. report evidence: app id + version, environment, architecture, install and
   update path, route used, logs

**Venue:** that environment must NOT run on b1. A privileged umbrelOS plus nested
app containers flattened b1's memory once already (2026-09-13, the VM: 9.5 GB of
swap, the box lagged for Damon). Damon's laptop, or a fresh box — decided when
the time comes, not assumed. See `start-vm.sh` in `/home/damon/umbrel-vm/` for the
qemu recipe that does boot umbrelOS (32 GB disk — the 6.1 GB download panics on
first boot because rugix cannot add partition 5).

## Submission mechanics

- Fork `getumbrel/umbrel-apps`; add the package as a top-level directory named by
  the app id (`depool-node` — verified free, as is host port 28700).
- Manifest for official packages: `submitter` (a person's name), `submission`
  (the PR URL once opened), `releaseNotes: ""` for a new package, `gallery: []`
  and **no `icon`** (their assets repo owns icons/gallery), `dependencies: []`,
  `path: ""`.
- Run the loop above first; then open the PR with the evidence attached.

## Three things a reviewer will ask about

- **The heartbeat to hashoid.io** — the box phones home and pairs with the tenant.
  The app mines and pays with hashoid.io unreachable (our harness runs exactly
  that dead-ORIGIN path), it needs no account, and the claim is optional. Say so
  plainly in the description rather than burying it.
- **Licence** — the images are BSL 1.1, Licensor Hashoid, change licence
  GPL-3.0-or-later after three years. Self-hosting is expressly granted; the
  carve-out is hosting a mining-pool service for third parties. Answer it head-on
  in the PR instead of waiting to be asked.
- **Bundling our own pruned Bitcoin node** instead of depending on the `bitcoin`
  app — justified by template sovereignty (getblocktemplate from our own node)
  and the Lightning settlement chain; worth stating, and worth revisiting whether
  the app should also satisfy the `bitcoin` dependency contract later.
