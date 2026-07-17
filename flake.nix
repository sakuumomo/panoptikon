{
  description = "Panoptikon: local multimodal media search (package, NixOS module, dev shells)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      panoptikonSrc =
        let
          ignore = [
            ".git"
            "target"
            "data"
            "runtime"
            "python-legacy"
            "node_modules"
            ".venv"
            "python/.venv"
            "ui/node_modules"
            "ui/.next"
            "panoptikon-desktop/src-tauri/target"
          ];
        in
        nixpkgs.lib.cleanSourceWith {
          src = self;
          filter =
            path: type:
            let
              base = baseNameOf path;
            in
            !(builtins.elem base ignore)
            && !(nixpkgs.lib.hasSuffix ".venv" base)
            && !(nixpkgs.lib.hasPrefix "result" base);
        };

      packageVersion =
        let
          cargo = builtins.fromTOML (builtins.readFile ./panoptikon/Cargo.toml);
        in
        cargo.package.version;

      packageOverlay = final: prev: {
        panoptikon = final.callPackage ./nix/package.nix {
          src = panoptikonSrc;
          version = packageVersion;
        };
        panoptikon-desktop = final.callPackage ./nix/desktop.nix {
          src = panoptikonSrc;
          version = packageVersion;
          panoptikon = final.panoptikon;
        };
      };
    in
    {
      overlays.default = packageOverlay;
      nixosModules.default = import ./nix/module.nix;
      nixosModules.panoptikon = self.nixosModules.default;
    }
    // flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ packageOverlay ];
        };

        lib = pkgs.lib;
        isLinux = pkgs.stdenv.isLinux;
        isX86_64 = pkgs.stdenv.hostPlatform.isx86_64;
        python = pkgs.python312;

        commonPackages =
          with pkgs;
          [
            rustc
            cargo
            rustfmt
            clippy
            pkg-config
            openssl
            nodejs_24
            uv
            git
            ffmpeg
            python
            fontconfig
          ]
          ++ lib.optionals isLinux [
            libGL
            libglvnd
            glib
            zlib
            zstd
            stdenv.cc.cc.lib
            libx11
            libxext
            libxrender
            libsm
            libice
            freetype
            chromium
            dejavu_fonts
            noto-fonts
            webkitgtk_4_1
            gtk3
            libsoup_3
            librsvg
            libayatana-appindicator
          ];

        mkPanoptikonShell =
          {
            name,
            accelerator,
            extraPackages ? [ ],
          }:
          let
            allPackages = commonPackages ++ extraPackages;
            libraryPath = lib.makeLibraryPath allPackages;
          in
          pkgs.mkShell {
            name = "panoptikon-${name}";
            packages = allPackages;
            shellHook = ''
              export PANOPTIKON_NIX_SHELL=${accelerator}
              export UV_PYTHON="${python}/bin/python3.12"
              export UV_PYTHON_DOWNLOADS=never
              export LD_LIBRARY_PATH="${libraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              if [ -d /run/opengl-driver/lib ]; then
                export LD_LIBRARY_PATH="/run/opengl-driver/lib:$LD_LIBRARY_PATH"
              fi
              if [ -d /run/opengl-driver-32/lib ]; then
                export LD_LIBRARY_PATH="/run/opengl-driver-32/lib:$LD_LIBRARY_PATH"
              fi
              export XDG_DATA_DIRS="${pkgs.dejavu_fonts}/share:${pkgs.noto-fonts}/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"

              if _cfg="$("$UV_PYTHON" scripts/generate-nix-dev-config.py)"; then
                export PANOPTIKON_CONFIG_PATH="''${_cfg}"
              else
                echo "warning: failed to generate config/server/nix-dev.toml" >&2
              fi
              unset _cfg

              echo "Panoptikon nix shell: ${accelerator}"
              echo "  rustc/cargo/node/uv/python/fc-match on PATH"
              echo "  PANOPTIKON_CONFIG_PATH=''${PANOPTIKON_CONFIG_PATH:-<unset>}"
              echo "  next: cargo build -p panoptikon && panoptikon setup --accelerator ${accelerator}"
            '';
          };

        cpuShell = mkPanoptikonShell {
          name = "cpu";
          accelerator = "cpu";
        };

        cudaShell =
          if isLinux then
            mkPanoptikonShell {
              name = "cuda";
              accelerator = "cuda";
              extraPackages = with pkgs.cudaPackages_12_8; [
                cudatoolkit
                cudnn
                cuda_nvcc
              ];
            }
          else
            null;

        rocmShell =
          if isLinux && isX86_64 then
            mkPanoptikonShell {
              name = "rocm";
              accelerator = "rocm";
              extraPackages = import ./nix/rocm-packages.nix { inherit pkgs; };
            }
          else
            null;
      in
      {
        packages = {
          # Default follows nixpkgs config (CPU unless config.cuda/rocmSupport).
          default = pkgs.panoptikon;
          panoptikon = pkgs.panoptikon;
          panoptikon-cuda = pkgs.panoptikon.override { cudaSupport = true; };
          panoptikon-rocm = pkgs.panoptikon.override { rocmSupport = true; };
        }
        // lib.optionalAttrs isLinux {
          panoptikon-desktop = pkgs.panoptikon-desktop;
        };

        checks = {
          panoptikon = pkgs.panoptikon;
          panoptikon-cli = pkgs.panoptikon.passthru.tests.cli;
          panoptikon-install = pkgs.panoptikon.passthru.tests.install;
        }
        // lib.optionalAttrs isLinux {
          panoptikon-desktop = pkgs.panoptikon-desktop;
          panoptikon-desktop-install = pkgs.panoptikon-desktop.passthru.tests.install;
          panoptikon-nixos = pkgs.testers.runNixOSTest {
            imports = [ ./nix/tests/panoptikon.nix ];
            defaults.imports = [ self.nixosModules.default ];
          };
          panoptikon-nixos-rocm-config = pkgs.testers.runNixOSTest {
            imports = [ ./nix/tests/panoptikon-rocm-config.nix ];
            defaults.imports = [ self.nixosModules.default ];
          };
        };

        devShells = {
          default = cpuShell;
          cpu = cpuShell;
        }
        // lib.optionalAttrs (cudaShell != null) { cuda = cudaShell; }
        // lib.optionalAttrs (rocmShell != null) { rocm = rocmShell; };

        formatter = pkgs.nixfmt;
      }
    );
}
