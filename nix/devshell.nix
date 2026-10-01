# Dev shells for zalo-for-linux.
#
# `fhs`   — buildFHSEnv sandbox: everything needed to build AND run the app on
#           NixOS (Electron 22, electron-builder and appimagetool are prebuilt
#           glibc binaries that do not run in a plain Nix shell).
# `light` — plain mkShell: no FHS sandbox. Fine for editing, cargo and native
#           addon builds; Electron and AppImage packaging will not run.
#
# The call bridge needs two things that do not exist in a vanilla Nix shell:
#   * a 32-bit compiler for streamproxy.so -> gcc_multi (multilib) + i686 X libs
#   * an i686 mingw cross compiler         -> pkgsCross.mingw32 (+ mcfgthread)
# Both are exposed through wrapper executables named the way the build scripts
# expect (`gcc`, `i686-w64-mingw32-gcc`), so no project script changes.
{ pkgs }:
let
  inherit (pkgs) lib;

  isX86_64 = pkgs.stdenv.hostPlatform.isx86_64;

  # Pinned to a specific stable release (not `latest`) for reproducibility.
  rustVersion = "1.98.1";
  rustToolchain = pkgs.rust-bin.stable.${rustVersion}.default.override {
    extensions = [
      "rustfmt"
      "clippy"
      "rust-analyzer"
    ];
  };

  # ---------------------------------------------------------------------------
  # Toolchain shared by both shells.
  # ---------------------------------------------------------------------------
  nativeTools = with pkgs; [
    nodejs_22
    git
    gnumake
    cmake
    pkg-config
    python3
    curl
    wget
    unzip
    xz
    zstd
    cacert
    which
    file
    patchelf
    openssl
    zlib
    nasm
    p7zip
    zsync
    rustToolchain
  ];

  # Build a wrapper executable, installed as bin/<name>.
  mkBin =
    name: priority: script:
    pkgs.runCommandLocal "zalo-wrapper-${name}" { meta.priority = priority; } ''
      mkdir -p $out/bin
      cat > $out/bin/${name} <<'WRAPPER'
      ${script}
      WRAPPER
      chmod +x $out/bin/${name}
    '';

  # ---------------------------------------------------------------------------
  # 32-bit / cross wrappers (x86_64 only).
  # ---------------------------------------------------------------------------
  i686 = pkgs.pkgsi686Linux;

  # `setup-zcall-bridge.js` runs `gcc -m32 … -lX11 -lxcb`. A plain nixpkgs gcc
  # is built --disable-multilib, so this shim wraps gcc_multi and adds the
  # 32-bit X include/lib paths only when `-m32` is on the command line.
  # 64-bit builds (node-gyp, the cc crate) pass through untouched.
  gccM32 = mkBin "gcc" 0 ''
    for arg in "$@"; do
      if [ "$arg" = "-m32" ]; then
        exec ${pkgs.gcc_multi}/bin/gcc \
          -I${i686.xorgproto}/include \
          -I${i686.libX11.dev}/include \
          -I${i686.libxcb.dev}/include \
          -I${i686.libXext.dev}/include \
          -L${i686.libX11}/lib \
          -L${i686.libxcb}/lib \
          -L${i686.libXext}/lib \
          "$@"
      fi
    done
    exec ${pkgs.gcc_multi}/bin/gcc "$@"
  '';

  mingwCC = pkgs.pkgsCross.mingw32.stdenv.cc;
  # nixpkgs mingw uses the mcfgthread thread model, so the linker needs its
  # library in the search path (the cc wrapper already adds `-lmcfgthread`).
  mcfgthreads = pkgs.pkgsCross.mingw32.windows.mcfgthreads;
  mingwGcc = mkBin "i686-w64-mingw32-gcc" 5 ''
    exec ${mingwCC}/bin/i686-w64-mingw32-gcc -L${mcfgthreads}/lib "$@"
  '';

  wrappers = lib.optionals isX86_64 [
    gccM32
    mingwGcc
  ];

  # Put the wrappers ahead of every other bin dir so `gcc` and
  # `i686-w64-mingw32-gcc` resolve to them (PATH collision order is not
  # reliable in a mkShell, and priority only matters for the FHS buildEnv).
  wrapperPath = lib.concatMapStringsSep ":" (w: "${w}/bin") wrappers;
  wrapperPathExport = lib.optionalString (wrappers != [ ]) ''
    export PATH="${wrapperPath}:$PATH"
  '';

  # ---------------------------------------------------------------------------
  # FHS payload: Electron 22 / electron-builder / appimagetool runtime libs,
  # a compiler, and wine.
  # ---------------------------------------------------------------------------
  electronLibs = with pkgs; [
    nss
    nspr
    gtk3
    gdk-pixbuf
    glib
    cairo
    pango
    harfbuzz
    atk
    at-spi2-atk
    at-spi2-core
    cups
    dbus
    libdrm
    mesa
    libgbm
    libGL
    libX11
    libxcb
    libXext
    libXrandr
    libXcursor
    libXi
    libXcomposite
    libXdamage
    libXfixes
    libXtst
    libXrender
    libxshmfence
    libxkbcommon
    alsa-lib
    pulseaudio
    systemd
    fontconfig
    freetype
    expat
    krb5
    libappindicator-gtk3
    libnotify
    util-linux
    fuse3
  ];

  fhsPackages =
    nativeTools
    ++ wrappers
    ++ lib.optionals isX86_64 [
      pkgs.gcc_multi
      # wow64 build: runs 32-bit PE binaries (ZaloCall.exe) without a full
      # multilib wine install.
      pkgs.wineWow64Packages.stable
    ]
    ++ electronLibs;

  # 32-bit libraries for wine (and for loading the compiled streamproxy.so).
  multiLibs =
    p:
    lib.optionals isX86_64 [
      p.libX11
      p.libxcb
      p.libXext
      p.libXrender
      p.libXrandr
      p.libXi
      p.mesa
      p.libGL
      p.libdrm
      p.alsa-lib
      p.pulseaudio
      p.zlib
      p.glib
      p.freetype
      p.fontconfig
      p.expat
    ];

  banner = ''
    echo "zalo-for-linux dev shell"
    echo "  node $(node --version 2>/dev/null) · $(cargo --version 2>/dev/null)"
    echo "  Build: npm ci && npm run main:setup && npm run main:build"
    echo "  Run:   npm start"
  '';

  fhsBwrap = pkgs.buildFHSEnv {
    name = "zalo-dev-fhs";

    targetPkgs = _: fhsPackages;
    multiPkgs = multiLibs;
    multiArch = isX86_64;

    # Sourced by the FHS init script, so it applies to interactive shells and to
    # commands run through `nix run .#fhs`.
    profile = ''
      # Run appimagetool and built AppImages without FUSE.
      export APPIMAGE_EXTRACT_AND_RUN=1
      # Electron's setuid sandbox is unusable inside the bwrap sandbox.
      export ELECTRON_DISABLE_SANDBOX=1
      ${wrapperPathExport}
    '';
  };
in
{
  # `.env` carries the bwrap `shellHook`, which is what an interactive
  # `nix develop` executes to enter the sandbox.
  fhs = fhsBwrap.env;

  # The bwrap wrapper itself, for running one-off commands inside the sandbox
  # (the arguments are passed to bash, hence `-c`):
  #   nix run .#fhs -- -c 'npm ci'
  fhsRun = fhsBwrap;

  light = pkgs.mkShell {
    packages = nativeTools ++ wrappers ++ lib.optionals isX86_64 [ pkgs.gcc_multi ];

    shellHook = ''
      export APPIMAGE_EXTRACT_AND_RUN=1
      ${wrapperPathExport}
      ${banner}
    '';
  };
}
