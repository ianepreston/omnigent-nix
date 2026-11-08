# omnigent-nix

A Nix flake for [Omnigent](https://github.com/omnigent-ai/omnigent): the server,
the host, and the desktop client, as separate packages with composable NixOS and
Home Manager modules.

| Role | What it does | Output |
| --- | --- | --- |
| Server | Persists sessions, serves the API and web UI | `nixosModules.omnigent`, `packages.<system>.omnigent` |
| Host | Executes agent sessions, terminals and tools | `packages.<system>.omnigent-host`, `homeManagerModules.omnigent` |
| Desktop | Electron shell around the server's web UI | `packages.<system>.omnigent-desktop` (Linux) |
| Runner image | Optional OCI image for provider-created hosts | `packages.<system>.omnigent-runner-image` (Linux) |

The server, host and desktop are separate products: installing the desktop does
not make the machine a host. A host runs arbitrary agent work with the
installing user's files, network and credentials, so nothing here starts one
unless you set `programs.omnigent.host.autoStart = true`.

This flake tracks **nixos-unstable** (and Home Manager `master`) because the
desktop needs `electron_45` and Omnigent moves fast. A consumer that pins a
stable `nixpkgs` (for example `nixos-26.05`, which has no `electron_45`) must not
point this flake at it. Either leave this flake's own nixpkgs alone, or follow an
unstable one:

```nix
inputs.omnigent.inputs.nixpkgs.follows = "nixpkgs-unstable";
```

Following a nixpkgs without `electron_45` makes `omnigent-desktop` fail
evaluation with a message saying exactly that; the server and host packages do
not need Electron. Python dependencies that upstream pins are built from the
locked releases, so they do not depend on the nixpkgs revision.

The package and modules are one lockstep unit pinned to a single upstream
release (`version` in `nix/source.nix`). Omnigent's self-updater (`omni upgrade`) and the desktop
auto-updater are disabled; you update with `nix flake update omnigent`.

## Outputs

```
packages.<system>.{omnigent, omnigent-host, omnigent-desktop, omnigent-runner-image,
                   omnigent-web-assets, default}      # default = omnigent
apps.<system>.{omnigent, omnigent-host}
nixosModules.{omnigent, caddy, postgresql, default}   # default = omnigent
homeManagerModules.{omnigent, default}                # default = omnigent
overlays.default                                      # pkgs.omnigent, pkgs.omnigent-host
checks.<system>.*  formatter.<system>
```

Systems: `x86_64-linux` (built and tested in CI), `aarch64-linux` and
`aarch64-darwin` (evaluated; built and tested in CI as advisory jobs, see
[Automation](#automation)). `x86_64-darwin` is dropped because nixpkgs 26.11 no longer
supports it. The desktop and the runner image are Linux outputs. This flake does
not yet build a macOS desktop bundle; on macOS use the upstream app (a packaging
limitation of this flake, not a property of Omnigent), and
`programs.omnigent.desktop.enable` on darwin fails with an explicit assertion
saying so.

## Server (NixOS)

```nix
{
  inputs.omnigent.url = "github:ianepreston/omnigent-nix";
  # One nixpkgs: this flake tracks nixos-unstable, so make it follow yours.
  inputs.omnigent.inputs.nixpkgs.follows = "nixpkgs-unstable"; # needs electron_45 for the desktop

  outputs = { nixpkgs, omnigent, ... }: {
    nixosConfigurations.server = nixpkgs.lib.nixosSystem {
      modules = [
        omnigent.nixosModules.omnigent
        {
          services.omnigent = {
            enable = true;
            publicUrl = "https://omnigent.example.net";
            environmentFile = "/run/secrets/omnigent.env";          # KEY=VALUE secrets, root-owned dir
            database.uriFile = "/run/secrets/omnigent-database-uri"; # postgresql+psycopg://…
          };
          # Bring your own proxy; the listener is http://127.0.0.1:8000 by default.
          services.caddy.virtualHosts."omnigent.example.net".extraConfig = ''
            reverse_proxy 127.0.0.1:8000
          '';
        }
      ];
    };
  };
}
```

What the core module does and does not do:

* Runs `omnigent-server` (upstream's external-runners-only entrypoint) as a
  hardened `DynamicUser` unit with `StateDirectory`. The server never executes
  agent work; do not register the server machine as a host.
* **Secret files** (`environmentFile`, `database.uriFile`) are delivered with
  systemd `LoadCredential=` (opened by PID 1), never `EnvironmentFile=`, which
  would hand variables such as `LD_PRELOAD` to a root helper. The unprivileged
  start wrapper *parses* the environment credential (it is never sourced) and
  accepts only an allowlist: `OMNIGENT_OIDC_*`, `OMNIGENT_GITHUB_APP_*`,
  `OMNIGENT_CREDENTIAL_*`, `OMNIGENT_ACCOUNTS_COOKIE_SECRET`,
  `OMNIGENT_ARTIFACT_URI`, `AWS_*` S3 credentials, plus
  `environmentFileKeys`. Anything else, including every module-controlled
  variable, stops the service from starting.
* A root `ExecStartPre` guard (run under `env -i`, so no secret or unit variable
  reaches it) refuses to start if a secret file resolves into `/nix/store`, or
  if the path (and its resolved target) is not on a chain of root-owned,
  non-group/world-writable components, so an unprivileged user cannot swap the
  source. Residual race: the credential is loaded by PID 1 before the guard
  runs, so the guard checks that the *source could not have been swapped by an
  unprivileged user*, not the loaded bytes; a root-equivalent attacker is out of
  scope.
* Module-controlled variables (host, port, database, auth, config path, update
  switches) are rejected in `environment` and force-set or unset by the wrapper
  after the credential is read. Authentication cannot be turned off from the
  environment.
* A literal `database.uri` is accepted only as `postgresql://`,
  `postgresql+psycopg://` or `postgres://` in an allowlisted passwordless form
  (bare username, allowlisted plain query keys); anything else must use
  `uriFile`.
* Binds loopback. A non-loopback `listen.address` fails evaluation unless
  `auth.provider` is set explicitly.
* Exactly one database source is required: `database.uriFile` (preferred, a
  systemd credential), `database.uri` (warns if it contains a password), or
  `database.sqlite.enable` (single-instance development only).
* `settings` is non-secret YAML rendered into the store. Secrets only ever come
  from the `environmentFile` / `database.uriFile` credentials.
* It owns no proxy, database service, secret manager, firewall or backups. It
  publishes `listen`, `listenUrl`, `publicUrl` and `healthPath` (`/health`) for
  your own integration.

Optional adapters (import only if you use stock upstream NixOS services):

```nix
imports = [ omnigent.nixosModules.caddy omnigent.nixosModules.postgresql ];
services.omnigent.caddy = { enable = true; hostName = "omnigent.example.net"; };
services.omnigent.postgresql.createLocally = true; # needs services.postgresql.enable
```

`caddy` adds one `services.caddy.virtualHosts` entry (HTTP/2, unbuffered
streaming) and checks that `hostName` matches `publicUrl`. `postgresql` creates a
database and role on an existing PostgreSQL service and connects over the unix
socket with peer authentication; it does not touch `pg_hba.conf`, the PostgreSQL
package, or passwords.

A repository with its own typed route/database/backup contracts should skip the
adapters and translate `services.omnigent.{listenUrl,publicUrl,healthPath,stateDir}`
in a small local module.

## Host and desktop (Home Manager)

```nix
{
  imports = [ omnigent.homeManagerModules.omnigent ];

  programs.omnigent = {
    host = {
      enable = true;                       # installs tools; starts nothing
      serverUrl = "https://omnigent.example.net";
      autoStart = false;                   # opt in to a user service / LaunchAgent
      harnesses.codex.enable = true;       # codex (default), claude-code, opencode, goose
    };
    desktop.enable = true;                 # independent of the host
  };
}
```

You log in interactively (`omnigent login`, `codex login`); no credentials are
Nix options. The harness executables come from nixpkgs, never from Omnigent's
npm-based installer. Run a host once by hand with
`omnigent host --server https://omnigent.example.net`.

## How it is built

* **Python.** The three lockstep distributions (`omnigent`, `omnigent-client`,
  `omnigent-ui-sdk`) are built from the tagged source and installed in one
  closure. `omnigent-client` requires `omnigent==X` in its metadata and also
  imports `omnigent.*` at runtime, so that back-edge is only satisfied in this
  single closure (`checks.*.client-needs-omnigent`). `cel-python` (not in
  nixpkgs) is installed from its pinned PyPI wheel; everything else, including
  `google-re2` and `psycopg`, comes from nixpkgs.
* **`sys.executable`.** Omnigent respawns itself with `sys.executable -P -m …`
  and runs git helpers with `sys.executable -I` (which ignores `PYTHONPATH`).
  The `bin/` entry points therefore run on a `python3.withPackages` interpreter
  that sees the whole closure itself, with no `PYTHONPATH` leaking into the
  subprocesses agents launch (`checks.*.child-interpreter`).
* **Web UI.** `pnpm` — pinned to the exact version upstream's `packageManager` names, from the npm registry, not nixpkgs' pnpm, so the dependency-store hash does not vary with the consumer's nixpkgs — installs upstream's locked workspace
  offline (`fetchPnpmDeps`); Vite builds the SPA, which is then bundled with
  `OMNIGENT_SKIP_WEB_UI=true` for the Python phase.
* **Deterministic metadata.** `setup.py` is patched to use `SOURCE_DATE_EPOCH`
  and the pinned commit instead of `time.time()` / `git rev-parse`.
* **No self-update.** `omni upgrade` fails with a pointer to the flake input;
  `OMNIGENT_NO_UPDATE_CHECK=1` silences the nag; the desktop's `electron-updater`
  is hard-disabled.
* **Desktop.** Runs on nixpkgs' `electron_45` (45.2.1, the major upstream targets; nothing is downloaded in the build). A patch makes CLI discovery prefer
  `$OMNIGENT_NIX_CLI`, which the wrapper sets to the co-built CLI, so Dock / `.desktop`
  launches with a minimal `PATH` still find it. Upstream already requires an
  explicit action before the desktop connects the machine as a host; the flake
  does not change that.
* **Desktop update overlay.** An upstream bug fix, not a packaging change: the
  update-toast child window could be resized to 0px tall when its parent window
  moved, which aborts Electron on Wayland under GNOME/mutter right after launch.
  The patch clamps it to the 1px sliver upstream intends. Drop it once upstream
  ships the fix.

Patches against upstream live in `nix/patches/`.

## Development

```sh
nix flake check 'path:.'
nix build 'path:.#omnigent' && ./result/bin/omnigent --version
nix build 'path:.#omnigent-host'
nix build 'path:.#omnigent-desktop'
```

Test a consumer against uncommitted changes without touching its lock file:

```sh
nix build --override-input omnigent 'path:/abs/path/to/omnigent-nix' \
  .#nixosConfigurations.<host>.config.system.build.toplevel
```

New files must be visible to flake evaluation (`git add -N <path>`) unless you
use a `path:` reference.

### Bumping Omnigent

Renovate normally does this for you (see [Automation](#automation)). By hand:

1. Edit `version` in `nix/source.nix`.
2. `scripts/update-hashes.sh` (Linux with Nix) regenerates the source hash,
   then re-syncs the pins copied from the new release
   (`scripts/sync-upstream-pins.py`: `commit` from the tag, the pnpm version from
   `packageManager`, `celPython` and every existing `pythonPins` entry from
   `uv.lock`), then regenerates the pnpm tarball and dependency-store hashes.
   It only updates existing Python pins; whether a package still needs pinning,
   or a new one does, is a judgement call.
3. `scripts/check-hash-independence.sh <consumer-nixpkgs-rev>` re-fetches every
   fixed-output derivation (source, pnpm dependency store, pinned sdists, the
   cel-python wheel) with `--rebuild` under this flake's nixpkgs and under the
   given revision, and fails on any hash mismatch. Pass the revision your consumer locks, e.g.
   `jq -r '.nodes["nixpkgs-unstable"].locked.rev' ../nixos/flake.lock`. (A plain
   build is not a proof: Nix skips a fixed-output derivation whose output is
   already in the store.)
4. `nix flake check`.

## Automation

[Renovate](https://docs.renovatebot.com/) (`renovate.json`) and GitHub Actions
(`.github/workflows/`) keep the flake current; every update arrives as a PR that
CI has built and tested, and a human merges it. Nothing auto-merges.

| What | How | Cadence |
| --- | --- | --- |
| Upstream Omnigent release | Regex manager on the `# renovate:` annotation in `nix/source.nix` (`github-tags`, PEP 440, final `X.Y.Z` only; release candidates and `.dev` tags are ignored). Rewrites `version` and `commit`. | As released |
| Hashes and lockfile pins for that release | `renovate-hashes.yml` runs `scripts/update-hashes.sh` and `scripts/check-hash-independence.sh` on the PR branch and pushes a `chore(deps): regenerate fixed-output hashes` commit. | On every push to a `renovate/**` branch that changes `nix/source.nix` |
| `flake.lock` (nixpkgs, home-manager) | Renovate lock file maintenance (`nix flake update`). Per-input digest PRs are disabled. | Weekly, before 06:00 Monday (America/Edmonton) |
| GitHub Actions | Renovate `github-actions` manager, SHA-pinned, grouped, 7-day minimum release age. | Weekly |

`check.yml` runs on every PR, on pushes to `main`, and on demand:

* **lint and evaluate** (ubuntu-latest): `flake.lock` matches `flake.nix`,
  `nix flake check --no-build --all-systems`, nixfmt, shellcheck, actionlint,
  `renovate-config-validator`.
* **build x86_64-linux** (ubuntu-latest, required): builds every package and
  every `checks.x86_64-linux.*` (building a check runs it), on a cold store, so
  every fixed-output hash is re-fetched and verified.
* **build aarch64-linux** (ubuntu-24.04-arm) and **build aarch64-darwin**
  (macos-latest): the same, but advisory (`continue-on-error`) until they have a
  green history; these systems were previously only evaluated.

No check is a NixOS VM test today; KVM is enabled on the x86_64-linux runner so
one added later runs there (GitHub's arm64 runners have no usable `/dev/kvm`). Substitution is plain cache.nixos.org (no extra cache).

The first `check` run on a fresh omnigent PR fails on the stale source hash;
it is superseded once the hash fixup commit lands.

### One-time setup

1. Install the [Renovate GitHub App](https://github.com/apps/renovate) on this
   repository. `renovate.json` is already present, so there is no onboarding PR;
   the Dependency Dashboard issue appears after the first run.
2. Create labels Renovate applies, or let it create them: `dependencies`,
   `upstream`, `flake-lock`, `ci`.
3. Recommended: give the hash fixup a token that triggers workflows. A push made
   with the default `GITHUB_TOKEN` does not start other workflows, so:
   * **GitHub App (recommended).** This repo reuses the existing personal app
     from `ianepreston/nixos` (its `FLAKE_UPDATE_APP_*`), installed on this
     repository too. If that app is unavailable, create a GitHub App owned by
     you with repository permission *Contents: read and write* and install it
     on this repository. Either way, set repository Actions secrets to the
     app's ID and a private key:
     `gh secret set RENOVATE_HASHES_APP_ID --body <app-id>` and
     `gh secret set RENOVATE_HASHES_APP_PRIVATE_KEY < app-private-key.pem`.
     Its push triggers `check` through the normal `pull_request` event.
   * **No secrets (fallback).** The fixup is pushed with `GITHUB_TOKEN` and the
     job then dispatches `check.yml` on the branch (`workflow_dispatch` is the
     one event `GITHUB_TOKEN` may start). The workflow requests the
     `contents: write` and `actions: write` it needs itself.
4. Optional: protect `main` and require the `build x86_64-linux` and
   `lint and evaluate` checks.

The fixup commit's author (`omnigent-nix-hash-regen@users.noreply.github.com`)
is listed in `gitIgnoredAuthors`, so Renovate keeps rebasing the PR onto newer
releases instead of treating it as human-edited.

### Running it by hand

* Re-run CI on any branch: `gh workflow run check.yml --ref <branch>`.
* Regenerate hashes on a branch: `gh workflow run renovate-hashes.yml --ref
  <branch>` (add `-f force=true` if the branch does not change
  `nix/source.nix`).
* Ask Renovate to check now: tick the box on the Dependency Dashboard issue.
* Validate the Renovate config locally:
  `npx --yes --package renovate -- renovate-config-validator --strict`
  (needs Node 24).

## Known limitations

* Python dependencies that upstream pins are built from upstream's locked
  releases (`pythonPins` in `nix/source.nix`: `openai`, `openai-agents`, `mcp`,
  `websockets`, `certifi`, at the versions in the tagged release's `uv.lock`)
  with every runtime-deps check on and no `pythonRelaxDeps`. Other dependencies track
  nixpkgs.
* This flake does not yet build a macOS desktop bundle; on macOS use the upstream
  app. (A packaging limitation of this flake, not a property of Omnigent.)
* `omnigent-runner-image` and the `withKubernetes` variant
  (`omnigent.override { withKubernetes = true; }`) are provided but have no
  automated cluster test; the flake creates no cluster resources.
