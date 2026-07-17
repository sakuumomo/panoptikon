# Nix packaging for Panoptikon

Package and NixOS module for the **current** Rust-era monorepo (bundled server
+ host_paths discovery + `--root` state layout).

**Flake input:** `nixpkgs` → `nixos-unstable`  
**Hosts:** NixOS 26.05 and current unstable (keep attrs dual-compatible)

## Runtime contract (must match `panoptikon` code)

| Flag / path | Meaning |
| --- | --- |
| `--root <dir>` | chdir base for all relative paths (required outside a checkout) |
| `--config <file>` | server TOML (module seeds under `<root>/config/…`) |
| `<root>/runtime/pysrc/` | extracted embedded Python (`bundled`) |
| `<root>/runtime/ui/` | extracted Next standalone (`bundled-ui`) |
| `<root>/runtime/venv` | managed uv venv (`panoptikon setup` / auto_setup) |
| `<root>/data/` | DBs / logs (`data_folder`) |

Host tools (see `panoptikon/src/host_paths.rs`) and setup:

| Need | How the package provides it |
| --- | --- |
| `node`, `ffmpeg`, `uv`, `chromium`, `fc-match`, `python3.12` | wrap `PATH` |
| Setup interpreter | `UV_PYTHON` + `UV_PYTHON_DOWNLOADS=never` (Nix CPython; no managed uv downloads / stub-ld) |
| Thumbnail fonts | pure `FONTCONFIG_FILE` (DejaVu) |
| CUDA `libcuda` | `/run/opengl-driver/lib` at runtime |
| ROCm HIP/HSA | module with `accelerator = "rocm"` installs `rocmPackages` into the system profile (`/run/current-system/sw/lib`); also `/opt/rocm/lib` if present; package wrap prepends both; workers use `rocm_env` |
| pdfium | venv `pypdfium2_raw` after setup |

Desktop’s sidecar is that same wrapped binary, so first-boot auto-setup inherits `UV_PYTHON`.

Do not put `/nix/store/...` paths into TOML for those.

## Build (this tree)

```bash
nix build .#panoptikon              # server (bundled + bundled-ui)
nix build .#panoptikon-desktop      # Tauri tray app + server sidecar
nix develop                         # dev shell (includes WebKit for desktop)
```

Package `src` is a filtered copy of **this** checkout, so server code
(`host_paths`, etc.) matches the tree. Desktop reuses `.#panoptikon` as the
Tauri `externalBin` sidecar (same pattern as release CI).

## NixOS module

```nix
{
  imports = [ inputs.panoptikon.nixosModules.default ];
  nixpkgs.overlays = [ inputs.panoptikon.overlays.default ];
  services.panoptikon = {
    enable = true;
    host = "127.0.0.1";
    port = 6342;
    accelerator = "rocm"; # cpu | cuda | rocm | auto
    # rocmOverrideGfx = "10.3.0"; # only if ISA mis-detected
    libraryPaths = [ "/mnt/media" ];
  };
}
```

Service:

- `ExecStart`: `panoptikon --root <stateDir> --config <stateDir>/config/server/default.toml --disable-update-check`
- tmpfiles creates `stateDir` before start (`ProtectSystem=strict` needs it)
- Seeds `nixos.toml` / inference example once into stateDir
- When `autoSetup = true`, **preStart** runs `panoptikon setup --if-needed` so
  multi-GB work is covered by `TimeoutStartSec` (restarts skip a full sync);
  with `accelerator = "rocm"` setup also HIP-probes the managed torch
- Env: `PANOPTIKON_HOST`, `PORT`, `ACCELERATOR`, `AUTO_SETUP` (in-process auto_setup still
  handles a stale lockfile after start)
- GPU (accelerator ≠ cpu): `/run/opengl-driver`, DRM/KFD `DeviceAllow`, user in
  `render`+`video`
- ROCm (`accelerator = "rocm"`): installs `clr`/runtime into system packages,
  sets `ROCM_PATH`/`HIP_PATH`, puts `rocminfo` on the unit PATH
- Warnings if `host` is non-loopback and/or `openFirewall` is set (not internet-hardened)

**Do not** bind non-loopback / open the firewall without a reverse proxy and a
matching non-loopback policy (seeded config only allows localhost under `allow_all`).

## Manual run of the built package

```bash
nix build .#panoptikon
ROOT=$(mktemp -d)
mkdir -p "$ROOT"/{config/server,config/inference,data,runtime}
cp result/share/panoptikon/nixos.toml "$ROOT/config/server/default.toml"
./result/bin/panoptikon --root "$ROOT" \
  --config "$ROOT/config/server/default.toml" \
  --disable-update-check
```

## Tests

Package smokes (no VM, no network):

```bash
nix build .#checks.x86_64-linux.panoptikon-cli
nix build .#checks.x86_64-linux.panoptikon-install
nix build .#checks.x86_64-linux.panoptikon-desktop-install
```

NixOS service VM test (`autoSetup = false`, curls `/api/client-config`):

```bash
nix build .#checks.x86_64-linux.panoptikon-nixos
```

The service test file is **`nix/tests/panoptikon.nix`** — written for
nixpkgs (`nixos/tests/…`), free of flake-local imports. The flake injects
`nixosModules.default` via `defaults.imports` when running the check.

## Submitting to nixpkgs

1. `nix/package.nix` → `pkgs/by-name/pa/panoptikon/package.nix`
2. `nix/module.nix` → e.g. `nixos/modules/services/web-apps/panoptikon.nix`
3. `nix/tests/panoptikon.nix` → `nixos/tests/panoptikon.nix` + register in
   `nixos/tests/all-tests.nix` (`panoptikon = runTest ./panoptikon.nix;`)
4. Package already wires `passthru.tests.nixos = nixosTests.panoptikon`
   when that attr exists
5. Set `src = fetchFromGitHub { rev = "…"; hash = "…"; fetchSubmodules = true; }`
6. Refresh UI pin + `npmDepsHash` when the submodule moves
7. `meta.maintainers`, module-list entry, nixpkgs-review

## Desktop package notes

- Linux only in this flake (WebKitGTK 4.1).
- Produces a native `panoptikon-desktop` binary + `panoptikon` sidecar on
  `PATH` next to it — not AppImage/DMG/NSIS (use upstream releases for those).
- Updater artifact signing is disabled at build time (`createUpdaterArtifacts`).
- Needs a graphical session / tray; not a systemd service (use
  `services.panoptikon` for headless server).
- Install smoke (`passthru.tests.install`) only checks binary layout and wrap;
  it does **not** launch a tray or exercise first-boot setup. First Desktop
  start still runs the sidecar’s normal setup path (multi-GB wheels when
  auto_setup is on) under the user’s session, not under the NixOS module.

## Gaps

- Inference lock is not Linux aarch64-complete (torch/triton).
- UI offline build still patches fonts until panoptikon-ui vendors Inter.
- Desktop packaging is binary-only (no AppImage/installer).
