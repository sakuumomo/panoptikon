# Nix packaging for Panoptikon

Bundled server + host_paths + `--root` state. Flake input: `nixpkgs` (unstable).

## Runtime contract

| Path | Meaning |
| --- | --- |
| `--root <dir>` | chdir base (required outside a checkout) |
| `<root>/config/` | server + inference TOML (module seeds once) |
| `<root>/runtime/{pysrc,ui,venv}/` | embedded Python, UI, managed uv venv |
| `<root>/data/` | DBs / logs |

| Need | Source |
| --- | --- |
| `node` / `ffmpeg` / `uv` / `chromium` / `fc-match` / `python3.12` | package `PATH` wrap |
| Setup interpreter | `UV_PYTHON` + `UV_PYTHON_DOWNLOADS=never` |
| Label fonts | `FONTCONFIG_FILE` (DejaVu) |
| CUDA / ROCm (package) | nixpkgs `config.cudaSupport` / `rocmSupport` (or `.override`) |
| CUDA / ROCm (service) | `services.panoptikon.accelerator` → devices, HIP, setup, package wrap |
| Workers HIP | `rocm_env` + wrap when package has `rocmSupport` |
| pdfium | venv after setup |

Do not put `/nix/store/...` tool paths into TOML.

## Build (this tree)

```bash
nix build .#panoptikon              # follows nixpkgs config (default CPU)
nix build .#panoptikon-rocm         # .override { rocmSupport = true; }
nix build .#panoptikon-cuda         # .override { cudaSupport = true; }
nix build .#panoptikon-desktop
nix develop
```

Package flags are standard nixpkgs GPU args (`config.*` + `.override`, not both).

## NixOS module

```nix
{
  imports = [ inputs.panoptikon.nixosModules.default ];
  nixpkgs.overlays = [ inputs.panoptikon.overlays.default ];
  # optional: nixpkgs.config.rocmSupport = true;  # default accelerator becomes "rocm"
  services.panoptikon = {
    enable = true;
    host = "127.0.0.1";
    port = 6342;
    accelerator = "rocm"; # cpu | cuda | rocm | auto
    # rocmOverrideGfx = "10.3.0";
    libraryPaths = [ "/mnt/media" ];
  };
}
```

- **`accelerator`** drives setup, devices, and rebuilds `package` with matching
  `cudaSupport` / `rocmSupport` (nixpkgs package flags — not both)
- Default accelerator: `rocm` / `cuda` if that nixpkgs config flag alone is set, else `cpu`
- `rocm`: HIP packages, KFD, `ROCM_PATH`/`HIP_PATH`, wrap with host HIP paths
- `cuda`: NVIDIA devices, opengl-driver bind, CUDA package wrap
- Do not expose non-loopback without a reverse proxy + matching policy

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

NixOS VM tests (`autoSetup = false`):

```bash
nix build .#checks.x86_64-linux.panoptikon-nixos
nix build .#checks.x86_64-linux.panoptikon-nixos-rocm-config
```

Tests under `nix/tests/` are nixpkgs-style; the flake injects the module via
`defaults.imports`.

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
