{
  lib,
  stdenv,
  rustPlatform,
  pkg-config,
  openssl,
  makeWrapper,
  wrapGAppsHook4,
  gtk3,
  webkitgtk_4_1,
  libsoup_3,
  librsvg,
  libayatana-appindicator,
  glib-networking,
  gst_all_1,
  runCommand,
  # Server sidecar (overridable: .override { panoptikon = panoptikon-rocm; }).
  panoptikon,
  src,
  version ? "0.1.5",
}:

let
  pname = "panoptikon-desktop";
  rustTarget = stdenv.hostPlatform.rust.rustcTarget;
  sidecarName = "panoptikon-${rustTarget}";
in
rustPlatform.buildRustPackage (finalAttrs: {
  inherit pname version src;

  cargoLock.lockFile = src + "/Cargo.lock";

  cargoBuildFlags = [
    "-p"
    "panoptikon-desktop"
  ];
  doCheck = false;

  nativeBuildInputs = [
    pkg-config
    makeWrapper
    wrapGAppsHook4
  ];

  buildInputs = [
    openssl
    gtk3
    webkitgtk_4_1
    libsoup_3
    librsvg
    libayatana-appindicator
    glib-networking
  ]
  ++ (with gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good
  ]);

  preConfigure = ''
    mkdir -p panoptikon-desktop/src-tauri/binaries
    cp -f ${panoptikon}/bin/panoptikon \
      panoptikon-desktop/src-tauri/binaries/${sidecarName}
    chmod +x panoptikon-desktop/src-tauri/binaries/${sidecarName}
  '';

  postPatch = ''
    substituteInPlace panoptikon-desktop/src-tauri/tauri.conf.json \
      --replace-fail '"createUpdaterArtifacts": true' \
                     '"createUpdaterArtifacts": false'
  '';

  # Sidecar is already wrapped; only wrap the tray binary.
  dontWrapGApps = true;

  postInstall = ''
    install -Dm755 ${panoptikon}/bin/panoptikon $out/bin/panoptikon
    install -Dm755 ${panoptikon}/bin/panoptikon \
      $out/libexec/panoptikon-desktop/${sidecarName}
  '';

  postFixup = ''
    wrapProgram $out/bin/panoptikon-desktop \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : $out/bin \
      --set-default WEBKIT_DISABLE_COMPOSITING_MODE 1
  '';

  passthru = {
    inherit panoptikon;
    tests = {
      install =
        runCommand "panoptikon-desktop-test-install"
          {
            meta.timeout = 60;
          }
          ''
            pkg=${finalAttrs.finalPackage}
            test -x "$pkg/bin/panoptikon-desktop"
            test -x "$pkg/bin/panoptikon"
            test -x "$pkg/libexec/panoptikon-desktop/${sidecarName}"
            grep -q UV_PYTHON "$pkg/bin/panoptikon"
            grep -q PATH "$pkg/bin/panoptikon-desktop"
            cmp -s "$pkg/bin/panoptikon" ${panoptikon}/bin/panoptikon
            touch $out
          '';
    };
  };

  meta = {
    description = "Panoptikon Desktop tray app (Tauri) with bundled Server sidecar";
    longDescription = ''
      Tauri tray app; server sidecar is the overridable panoptikon argument
      (PATH + externalBin). Graphical session required; headless: services.panoptikon.
    '';
    homepage = "https://github.com/reasv/panoptikon";
    license = lib.licenses.agpl3Plus;
    mainProgram = "panoptikon-desktop";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    maintainers = [ ];
  };
})
