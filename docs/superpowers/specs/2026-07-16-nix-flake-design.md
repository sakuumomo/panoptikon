# Nix flake design

Date: 2026-07-16  
**Status: superseded in scope** — original design was **dev shells only**.  
Current tree also ships **packages**, a **NixOS module**, and **tests**.  
Authoritative packaging docs: [`nix/README.md`](../../../nix/README.md).

## Original goal (still valid for shells)

Repository-root Nix flake with multi-accelerator **development shells**
(`cpu` / `cuda` / `rocm`) for the Rust server + Python workers + UI tooling.

## Current scope (implemented)

| Output | Role |
| --- | --- |
| `devShells.default` / `cpu` / `cuda` / `rocm` | Dev shells (`nix develop`) |
| `packages.panoptikon` | Bundled server (`bundled` + `bundled-ui`) |
| `packages.panoptikon-desktop` | Tauri tray + server sidecar (Linux) |
| `nixosModules.default` | `services.panoptikon` |
| `checks.*` | Package smokes + NixOS VM test (`panoptikon-nixos`) |

**nixpkgs pin:** `nixos-unstable` (hosts on NixOS 26.05 remain a compatibility goal for package/module attrs).

**Runtime contract:** always `--root <writable>`; host tools via PATH / fontconfig / `host_paths` (no store paths required in TOML); `UV_PYTHON` + `UV_PYTHON_DOWNLOADS=never` on the package wrap.

## Shared shell packages (unchanged intent)

- `rustc`, `cargo`, `rustfmt`, `clippy`, `pkg-config`, OpenSSL
- `nodejs_24`, `uv`, `git`, `ffmpeg`, `python312`, `fontconfig`
- Linux: GL/X11 libs, chromium, fonts, WebKitGTK stack for local desktop builds
- CUDA / ROCm extras on respective shells

Shell hook: `UV_PYTHON`, `LD_LIBRARY_PATH`, optional opengl-driver, generate
`config/server/nix-dev.toml` (bare tool names), print next steps. Does **not**
auto-run setup/cargo/npm.

## Systems

- Packages / full shells: `x86_64-linux`, `aarch64-linux` (GPU shells Linux-only; ROCm x86_64)
- Darwin: CPU shell where attrs exist; no Linux-only packages

## Explicit gaps

- Inference lock not fully aarch64-linux complete
- UI offline build still patches Inter until panoptikon-ui vendors fonts
- Desktop is a native binary + sidecar, not AppImage/NSIS

## Out of scope (original list, partially overridden)

Original: “no installable packages, no Desktop”. **Overridden** — see `nix/`.
Still out of scope: full GPU e2e in CI, AppImage packaging.
