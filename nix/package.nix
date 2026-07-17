{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  openssl,
  nodejs_24,
  buildNpmPackage,
  ffmpeg,
  uv,
  python312,
  makeWrapper,
  makeFontsConf,
  fontconfig,
  dejavu_fonts,
  inter,
  chromium,
  libGL,
  libglvnd,
  glib,
  zlib,
  libx11,
  libxext,
  libxrender,
  libsm,
  libice,
  freetype,
  runCommand,
  nixosTests ? { },
  # Flake passes monorepo `src`; nixpkgs omits and uses fetchFromGitHub.
  src ? null,
  version ? "0.1.5",
}:

let
  pname = "panoptikon";

  finalSrc =
    if src != null then
      src
    else
      fetchFromGitHub {
        owner = "reasv";
        repo = "panoptikon";
        rev = "v${version}";
        hash = lib.fakeHash;
        fetchSubmodules = true;
      };

  # Flakes omit submodule contents; pin matches `git ls-tree HEAD ui`.
  uiSrc = fetchFromGitHub {
    owner = "reasv";
    repo = "panoptikon-ui";
    rev = "ac2f187c83bb63c71f5b04de682550ff756a842d";
    hash = "sha256-hKNTl3KRWTcCPQrRb6zL8MaD4yG3ItF2z4mUZvPF8+I=";
  };

  # Offline UI: patch next/font/google → local Inter (drop when UI vendors fonts).
  ui = buildNpmPackage {
    pname = "${pname}-ui";
    inherit version;
    src = uiSrc;

    npmDepsHash = "sha256-WOLmytdunatTpwLq7+IwMjrNrKrLAWvIDxOgt84D/98=";

    env = {
      BUILD_STANDALONE = "true";
      NODE_OPTIONS = "--max-old-space-size=8192";
      NEXT_TELEMETRY_DISABLED = "1";
    };

    makeCacheWritable = true;
    npmFlags = [ "--include=dev" ];

    postPatch = ''
      mkdir -p app/fonts
      cp ${inter}/share/fonts/truetype/InterVariable.ttf app/fonts/InterVariable.ttf
      node ${./patch-ui-offline-font.mjs} app/layout.tsx
    '';

    buildPhase = ''
      runHook preBuild
      npm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      test -f .next/standalone/server.js
      mkdir -p $out
      cp -a .next/standalone/. $out/
      cp -a .next/static $out/.next/static
      if [ -d public ]; then
        cp -a public $out/public
      fi
      runHook postInstall
    '';

    meta = {
      description = "Panoptikon web UI (Next.js standalone bundle)";
      license = lib.licenses.agpl3Plus;
    };
  };

  pythonRuntimeLibs = [
    stdenv.cc.cc.lib
    zlib
    openssl
    libGL
    libglvnd
    glib
    libx11
    libxext
    libxrender
    libsm
    libice
    fontconfig
    freetype
  ];

  fontsConf = makeFontsConf {
    fontDirectories = [ dejavu_fonts ];
  };

  runtimePath = lib.makeBinPath [
    nodejs_24
    ffmpeg
    uv
    python312
    fontconfig.bin
    chromium
  ];

  runtimeLibPath = lib.makeLibraryPath pythonRuntimeLibs;

in
rustPlatform.buildRustPackage (finalAttrs: {
  inherit pname version;
  src = finalSrc;

  cargoLock.lockFile = finalSrc + "/Cargo.lock";

  cargoBuildFlags = [
    "-p"
    "panoptikon"
    "--features"
    "bundled,bundled-ui"
  ];
  doCheck = false;

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];

  buildInputs = [
    openssl
  ];

  env = {
    LIBSQLITE3_FLAGS = "-DSQLITE_ENABLE_MATH_FUNCTIONS";
    PANOPTIKON_UI_BUNDLE = "${ui}";
  };

  postPatch = ''
    substituteInPlace Cargo.toml \
      --replace-fail ', "panoptikon-desktop/src-tauri"' ""
  '';

  postInstall = ''
    install -Dm644 config/server/nixos.toml \
      $out/share/panoptikon/nixos.toml
    install -Dm644 config/inference/example.toml \
      $out/share/panoptikon/inference-example.toml

    wrapProgram $out/bin/panoptikon \
      --prefix PATH : ${runtimePath} \
      --prefix LD_LIBRARY_PATH : ${runtimeLibPath} \
      --set FONTCONFIG_FILE ${fontsConf} \
      --set UV_PYTHON ${python312}/bin/python3.12 \
      --set UV_PYTHON_DOWNLOADS never \
      --run 'if [ -d /run/opengl-driver/lib ]; then export LD_LIBRARY_PATH="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; fi'
  '';

  passthru.tests = {
    cli =
      runCommand "panoptikon-test-cli"
        {
          nativeBuildInputs = [ finalAttrs.finalPackage ];
          meta.timeout = 60;
        }
        ''
          panoptikon --version | grep -F ${lib.escapeShellArg finalAttrs.version}
          panoptikon --help | grep -q "Panoptikon media indexing"
          panoptikon --help | grep -q -- "--root"
          panoptikon setup --help | grep -q accelerator
          panoptikon setup --help | grep -q if-needed
          touch $out
        '';

    install =
      runCommand "panoptikon-test-install"
        {
          meta.timeout = 60;
        }
        ''
          bin=${finalAttrs.finalPackage}/bin/panoptikon
          share=${finalAttrs.finalPackage}/share/panoptikon
          test -x "$bin"
          test -f "$share/nixos.toml"
          test -f "$share/inference-example.toml"
          grep -q 'data_folder' "$share/nixos.toml"
          grep -q UV_PYTHON "$bin"
          grep -q UV_PYTHON_DOWNLOADS "$bin"
          grep -q FONTCONFIG_FILE "$bin"
          grep -q opengl-driver "$bin"
          grep -q nodejs "$bin"
          grep -q ffmpeg "$bin"
          grep -q '/bin/uv' "$bin" || grep -q uv- "$bin"
          touch $out
        '';
  }
  // lib.optionalAttrs (nixosTests ? panoptikon) {
    nixos = nixosTests.panoptikon;
  };

  meta = {
    description = "Local multimodal media search engine (Rust server + AI workers + web UI)";
    longDescription = ''
      Bundled server (features bundled + bundled-ui) with PATH wrap for
      node/ffmpeg/uv/python3.12/fc-match/chromium, UV_PYTHON for Nix CPython,
      and FONTCONFIG_FILE for labels. Always run with --root <writable-dir>.
    '';
    homepage = "https://github.com/reasv/panoptikon";
    license = lib.licenses.agpl3Plus;
    mainProgram = "panoptikon";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    maintainers = [ ];
  };
})
