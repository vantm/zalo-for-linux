# Hermetic, from-source build of Zalo for Linux.
#
# The upstream pipeline downloads the proprietary macOS client at build time and
# packages it with electron-builder + quick-sharun. Inside the Nix sandbox
# nothing is fetched at build time: every upstream artifact is a fixed-output
# derivation pinned in ./versions.nix, every JavaScript and Rust dependency is
# vendored, and the app is packaged by hand instead of electron-builder /
# quick-sharun.
{ pkgs }:
let
  inherit (pkgs) lib;
  versions = import ./versions.nix;

  # ---------------------------------------------------------------------------
  # Fixed-output inputs.
  # ---------------------------------------------------------------------------
  zaloDmg = pkgs.fetchurl {
    url = "https://res-download-pc.zadn.vn/mac/ZaloSetup-universal-${versions.zaloVersion}.dmg";
    hash = versions.hashes.dmg;
  };

  zaloWinExe = pkgs.fetchurl {
    url = "https://res-download-pc.zadn.vn/win/ZaloSetup-${versions.zaloWinVersion}.exe";
    hash = versions.hashes.win;
  };

  wineTarball = pkgs.fetchurl {
    url = "https://github.com/Kron4ek/Wine-Builds/releases/download/${versions.wineVersion}/wine-${versions.wineVersion}-amd64.tar.xz";
    hash = versions.hashes.wine;
  };

  zadarkSrc = pkgs.fetchurl {
    url = "https://github.com/quaric/zadark/archive/refs/tags/${versions.zadarkVersion}.tar.gz";
    hash = versions.hashes.zadark;
  };

  electronSrc = pkgs.fetchurl {
    url = "https://github.com/electron/electron/releases/download/v${versions.electronVersion}/electron-v${versions.electronVersion}-linux-x64.zip";
    hash = versions.hashes.electron;
  };

  sqlite3Prebuilt = pkgs.fetchurl {
    url = "https://github.com/TryGhost/node-sqlite3/releases/download/v${versions.sqlite3Version}/sqlite3-v${versions.sqlite3Version}-napi-v6-linux-x64.tar.gz";
    hash = versions.hashes.sqlite3;
  };

  # ---------------------------------------------------------------------------
  # Runtime libraries. Shared with the dev shell (nix/runtime-libs.nix) so both
  # expose the same closure. The package wraps the app in an FHS (see mkZalo):
  # Chromium only launches its helper processes correctly inside a real
  # filesystem view, so a plain RPATH derivation shows no window. The same list
  # still feeds autoPatchelfHook for the Electron binary's DT_NEEDED graph.
  # ---------------------------------------------------------------------------
  runtime = import ./runtime-libs.nix { inherit pkgs; };
  runtimeLibs = runtime.electronLibs ++ [ pkgs.stdenv.cc.cc.lib ];

  # ---------------------------------------------------------------------------
  # Electron 22 runtime, patched for NixOS.
  # ---------------------------------------------------------------------------
  electronDist = pkgs.stdenv.mkDerivation {
    pname = "zalo-electron";
    version = versions.electronVersion;

    src = electronSrc;

    dontConfigure = true;
    dontBuild = true;

    # The Electron zip has its payload at the archive root, which the generic
    # unpacker rejects.
    unpackPhase = ''
      runHook preUnpack
      unzip -q "$src"
      runHook postUnpack
    '';

    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      pkgs.unzip
    ];

    buildInputs = runtimeLibs;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib/zalo
      cp -r . $out/lib/zalo/

      # A setuid helper is meaningless inside the Nix store; the wrapper runs
      # with the sandbox disabled instead.
      rm -f $out/lib/zalo/chrome-sandbox

      runHook postInstall
    '';

    meta = {
      description = "Electron ${versions.electronVersion} runtime bundled with Zalo";
      platforms = [ "x86_64-linux" ];
    };
  };

  nodejs = pkgs.nodejs_22;

  # ---------------------------------------------------------------------------
  # JavaScript build dependencies.
  # ---------------------------------------------------------------------------
  # asar + fs-extra + node-html-parser, used by the upstream patch scripts.
  buildTools = pkgs.importNpmLock.buildNodeModules {
    npmRoot = ./tools;
    nodejs = pkgs.nodejs_22;
  };

  # Upstream's prepare-zadark.js adds four exports to src/pc/zadark-pc.js before
  # running gulp; replicate that so the built module exposes them.
  zadarkExportsPatch = pkgs.writeText "zadark-exports.js" ''
    const fs = require("fs");
    const file = "src/pc/zadark-pc.js";
    let content = fs.readFileSync(file, "utf8");
    content = content.replace(
      /,\s*uninstallZaDark\s*\}/,
      ",\n  uninstallZaDark,\n\n  // Additional exports for build integration\n  copyZaDarkAssets,\n  writeIndexFile,\n  writeBootstrapFile,\n  writePopupViewerFile\n}"
    );
    fs.writeFileSync(file, content);
  '';

  # ZaDark (dark-mode extension) built from its pinned source. The manifest and
  # lockfile live in nix/ because plugins/zadark is a submodule we cannot commit
  # into; the only edit is an npm override replacing a git dependency
  # (`gulp-crx-pack` -> `crx`, ssh git URL) with the registry build.
  zadarkBuild = pkgs.buildNpmPackage {
    pname = "zadark";
    version = versions.zadarkVersion;
    src = zadarkSrc;
    nodejs = pkgs.nodejs_22;
    npmDepsHash = versions.npmHashes.zadark;
    npmFlags = [ "--ignore-scripts" ];

    postPatch = ''
      cp ${./zadark-package.json} package.json
      cp ${./zadark-package-lock.json} package-lock.json
      node ${zadarkExportsPatch}
    '';

    buildPhase = ''
      runHook preBuild
      NODE_ENV=production ./node_modules/.bin/gulp build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r build $out/build
      cp -r node_modules $out/node_modules
      runHook postInstall
    '';
  };

  # ---------------------------------------------------------------------------
  # Native addons, reimplemented from source.
  # ---------------------------------------------------------------------------
  rustAddon =
    {
      pname,
      libName,
      dir,
    }:
    pkgs.rustPlatform.buildRustPackage {
      inherit pname;
      version = "1.0.0";
      src = dir;
      cargoLock.lockFile = dir + "/Cargo.lock";

      nativeBuildInputs = [
        pkgs.nasm
        pkgs.pkg-config
      ];

      doCheck = false;

      # cdylib: there is no binary to install, only the .so.
      installPhase = ''
        runHook preInstall
        mkdir -p $out/lib
        so=$(find . -name "lib${libName}.so" -print -quit)
        if [ -z "$so" ]; then
          echo "error: lib${libName}.so not found; .so files present:"
          find . -name '*.so' | head -20
          exit 1
        fi
        cp "$so" $out/lib/lib${libName}.so
        runHook postInstall
      '';
    };

  nativelibs = {
    zimage = rustAddon {
      pname = "zimage";
      libName = "zimage";
      dir = ../nativelibs/zimage;
    };
    zjxl = rustAddon {
      pname = "zjxl";
      libName = "zjxl";
      dir = ../nativelibs/zjxl;
    };
    mp4thumb = rustAddon {
      pname = "mp4thumb";
      libName = "mp4thumb";
      dir = ../nativelibs/mp4thumb;
    };
    file-utils = rustAddon {
      pname = "file-utils";
      libName = "file_utils";
      dir = ../nativelibs/file-utils;
    };
    file-utilities = rustAddon {
      pname = "file-utilities";
      libName = "file_utilities";
      dir = ../nativelibs/file-utilities;
    };
  };

  dbCrossV4 =
    let
      addonNodeModules = pkgs.importNpmLock.buildNodeModules {
        npmRoot = ../nativelibs/db-cross-v4;
        nodejs = pkgs.nodejs_22;
      };
    in
    pkgs.stdenv.mkDerivation {
      pname = "db-cross-v4";
      version = "1.0.0";
      src = ../nativelibs/db-cross-v4;

      nativeBuildInputs = [ pkgs.pkg-config ];
      buildInputs = [
        pkgs.openssl
        pkgs.xz
      ];

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild
        $CXX -std=c++17 -O2 -fPIC -shared -DNAPI_DISABLE_CPP_EXCEPTIONS \
          -I${addonNodeModules}/node_modules/node-addon-api \
          -I${nodejs}/include/node \
          src/main.cc -llzma -lcrypto -o db-cross-v4-native.node
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp db-cross-v4-native.node $out/
        runHook postInstall
      '';
    };

  # ---------------------------------------------------------------------------
  # Call bridge: a 32-bit LD_PRELOAD shim (streamproxy.so) and an i686 mingw
  # named-pipe pump (pipebridge.exe).
  # ---------------------------------------------------------------------------
  i686 = pkgs.pkgsi686Linux;
  mingwCC = pkgs.pkgsCross.mingw32.stdenv.cc;
  mcfgthreads = pkgs.pkgsCross.mingw32.windows.mcfgthreads;

  # Wine for the call engine. The upstream portable Kron4ek build needs 32-bit
  # host libraries, which NixOS does not provide; nixpkgs' wow64 build runs the
  # 32-bit ZaloCall/pipebridge under a 64-bit host and is pointed at with
  # ZCALL_WINE (the plugin's highest-priority wine).
  wine = pkgs.wineWow64Packages.stable;

  zcallBridge = pkgs.stdenv.mkDerivation {
    pname = "zalo-zcall-bridge";
    version = "1.0.0";
    src = ../zcall-bridge;

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      ${pkgs.gcc_multi}/bin/gcc -m32 -shared -fPIC -O2 streamproxy.c \
        -I${i686.xorgproto}/include \
        -I${i686.libX11.dev}/include \
        -I${i686.libxcb.dev}/include \
        -I${i686.libXext.dev}/include \
        -L${i686.libX11}/lib \
        -L${i686.libxcb}/lib \
        -L${i686.libXext}/lib \
        -ldl -lX11 -lxcb -o streamproxy.so

      ${mingwCC}/bin/i686-w64-mingw32-gcc pipebridge.c \
        -lws2_32 -O2 -L${mcfgthreads}/lib -o pipebridge.exe

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp streamproxy.so pipebridge.exe $out/
      runHook postInstall
    '';
  };

  # Qt call runtime (ZaloCall.exe + DLLs) extracted from the Windows installer.
  # Mirrors setup-zcall-bridge.js, including its trim list.
  zcallRuntime = pkgs.stdenv.mkDerivation {
    pname = "zalo-call-runtime";
    version = versions.zaloWinVersion;
    src = zaloWinExe;

    dontUnpack = true;
    dontConfigure = true;

    nativeBuildInputs = [ pkgs.p7zip ];

    buildPhase = ''
      runHook preBuild

      mkdir -p extract capture
      7z e -y "$src" '$PLUGINSDIR/app-32.7z' -oextract
      7z x -y extract/app-32.7z "Zalo-${versions.zaloWinVersion}/plugins/capture/*" -ocapture

      capture_dir="capture/Zalo-${versions.zaloWinVersion}/plugins/capture"
      rm -rf "$capture_dir"/{pdbs,translations,bearer,iconengines,playlistformats,sqldrivers,styles}
      rm -f "$capture_dir"/{opengl32sw.dll,Qt5Sql.dll,Qt5Xml.dll}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r capture/Zalo-${versions.zaloWinVersion}/plugins/capture $out/qt-call-and-cap
      runHook postInstall
    '';
  };

  # ---------------------------------------------------------------------------
  # Assemble the patched Zalo app tree by driving the upstream patch scripts
  # offline: FOD inputs are pre-placed, native addons are pre-built, and the
  # in-place compiler invocations are neutralised with no-op shims.
  # ---------------------------------------------------------------------------
  zaloApp = pkgs.stdenv.mkDerivation {
    pname = "zalo-app";
    version = versions.zaloVersion;
    src = ../.;

    nativeBuildInputs = [
      nodejs
      pkgs.p7zip
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      # Root node_modules: only the build-time JS tools are needed.
      rm -rf node_modules
      cp -r ${buildTools}/node_modules node_modules
      chmod -R u+w node_modules

      # sqlite3 N-API prebuilt, at the path patch-sqlite3.js expects.
      mkdir -p node_modules/sqlite3/build/Release
      tar xzf ${sqlite3Prebuilt} -C node_modules/sqlite3

      # Pre-built native addons, staged where the builder helpers look for them.
      mkdir -p nativelibs/db-cross-v4/build/Release
      cp ${dbCrossV4}/db-cross-v4-native.node nativelibs/db-cross-v4/build/Release/

      stage_so() {
        mkdir -p "nativelibs/$1/target/release"
        cp "$2" "nativelibs/$1/target/release/$3"
      }
      stage_so file-utils      ${nativelibs.file-utils}/lib/libfile_utils.so        libfile_utils.so
      stage_so file-utilities  ${nativelibs.file-utilities}/lib/libfile_utilities.so libfile_utilities.so
      stage_so mp4thumb        ${nativelibs.mp4thumb}/lib/libmp4thumb.so            libmp4thumb.so
      stage_so zimage          ${nativelibs.zimage}/lib/libzimage.so                libzimage.so
      stage_so zjxl            ${nativelibs.zjxl}/lib/libzjxl.so                    libzjxl.so

      # ZaDark is pre-built; place it where integrateZaDark/patch-zadark-keep read it.
      mkdir -p plugins/zadark
      rm -rf plugins/zadark/build plugins/zadark/node_modules
      cp -r ${zadarkBuild}/build plugins/zadark/build
      cp -r ${zadarkBuild}/node_modules plugins/zadark/node_modules

      # The DMG the extractor picks up.
      mkdir -p temp
      ln -sf ${zaloDmg} "temp/ZaloSetup-universal-${versions.zaloVersion}.dmg"

      # Everything copied out of the store is read-only.
      chmod -R u+w .

      # Neutralise the in-place native compilers: the artifacts are already there.
      mkdir -p shims
      for tool in npm npx cargo; do
        printf '#!/bin/sh\nexit 0\n' > "shims/$tool"
        chmod +x "shims/$tool"
      done

      cat > driver.js <<'DRIVER'
      const path = require('path');

      (async () => {
        // Extract app.asar and apply every platform patch.
        await require('./scripts/prepare-app.js').main();

        // ZaDark integration (mirrors integrateZaDark in scripts/build.js).
        const root = process.cwd();
        const zadarkPC = require(path.join(root, 'plugins/zadark/build/pc/zadark-pc.js'));
        zadarkPC.copyZaDarkAssets(root);
        zadarkPC.writeIndexFile(root);
        zadarkPC.writeBootstrapFile(root);
        zadarkPC.writePopupViewerFile(root);
        await require('./scripts/patches/patch-zadark-keep').main(path.join(root, 'app'));
      })().catch((e) => {
        console.error(e);
        process.exit(1);
      });
      DRIVER

      PATH="$PWD/shims:$PATH" \
        ZALO_VERSION="${versions.zaloVersion}" \
        ZALO_WIN_VERSION="${versions.zaloWinVersion}" \
        node driver.js

      # Call bridge + extracted ZaloCall runtime (done here so setup-zcall-bridge
      # does not try to reach the network).
      mkdir -p app/native/qt-call-and-cap
      cp -r ${zcallRuntime}/qt-call-and-cap/. app/native/qt-call-and-cap/
      cp ${zcallBridge}/streamproxy.so ${zcallBridge}/pipebridge.exe zcall-bridge/
      # The wine validator looks for pipebridge.exe next to ZaloCall.exe.
      cp ${zcallBridge}/pipebridge.exe app/native/qt-call-and-cap/

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r app $out/app
      cp -r zcall-bridge $out/zcall-bridge

      # The Electron entry point (electron-builder's `files` set).
      mkdir -p $out/resources-app/plugins
      cp main.js package.json $out/resources-app/
      for p in screenshot launcher-badge userscripts zcall-bridge tray-host start-hidden window-state; do
        cp -r "plugins/$p" "$out/resources-app/plugins/"
      done

      runHook postInstall
    '';
  };

  # The assembled application tree: Electron 22 + resources/app + app/ +
  # zcall-bridge/, with a wrapper that pins the runtime environment (wine,
  # gdk-pixbuf loaders, gsettings schemas). The FHS wrapper below executes this.
  mkZaloTree =
    { pname }:
    pkgs.stdenv.mkDerivation {
      inherit pname;
      version = versions.zaloVersion;

      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;

      nativeBuildInputs = [
        pkgs.makeWrapper
        pkgs.patchelf
      ];

      installPhase = ''
        runHook preInstall

        mkdir -p $out/opt/zalo $out/bin
        cp -r ${electronDist}/lib/zalo/. $out/opt/zalo/
        chmod -R u+w $out/opt/zalo

        cp -r ${zaloApp}/app $out/opt/zalo/app
        cp -r ${zaloApp}/zcall-bridge $out/opt/zalo/zcall-bridge
        mkdir -p $out/opt/zalo/resources/app
        cp -r ${zaloApp}/resources-app/. $out/opt/zalo/resources/app/

        # Everything copied out of the store is read-only.
        chmod -R u+w $out/opt/zalo

        # The upstream sqlite3 prebuilt carries no rpath; it needs libstdc++.
        sqlite_node=$out/opt/zalo/app/native/nativelibs/sqlite3/binding/napi-v6-linux-x64/node_sqlite3.node
        if [ -f "$sqlite_node" ]; then
          patchelf --set-rpath ${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]} "$sqlite_node"
        fi

        makeWrapper $out/opt/zalo/electron $out/bin/zalo \
          --add-flags "--no-sandbox" \
          --set ELECTRON_DISABLE_SANDBOX 1 \
          --set ZCALL_WINE "${wine}/bin/wine" \
          --set GDK_PIXBUF_MODULE_FILE "${pkgs.gdk-pixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" \
          --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
          --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}" \
          --prefix XDG_DATA_DIRS : "${pkgs.shared-mime-info}/share"

        runHook postInstall
      '';

      passthru = {
        inherit
          zaloDmg
          zaloWinExe
          wineTarball
          zadarkSrc
          electronSrc
          zaloApp
          ;
      };

      meta = {
        description = "Unofficial Zalo client for Linux (unwrapped app tree)";
        homepage = "https://github.com/doandat943/zalo-for-linux";
        license = lib.licenses.unfree;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        mainProgram = "zalo";
        platforms = [ "x86_64-linux" ];
      };
    };

  # Wrap the app tree in the same FHS environment the dev shell provides.
  # Chromium needs a real filesystem view (merged /usr/lib, /etc,
  # XDG_DATA_DIRS, GStreamer paths) to launch its helper processes; without it
  # the process starts but never shows a window. buildFHSEnv keeps the output a
  # normal package exposing `bin/zalo`.
  mkZalo =
    { pname }:
    pkgs.buildFHSEnv {
      inherit pname;
      version = versions.zaloVersion;

      # Keep the command name stable (`result/bin/zalo`) even though the
      # derivation is named after pname.
      executableName = "zalo";

      targetPkgs =
        _:
        runtime.electronLibs
        ++ (with pkgs; [
          wineWow64Packages.stable
          xdg-utils
        ]);

      multiPkgs = runtime.multiLibs;
      multiArch = pkgs.stdenv.hostPlatform.isx86_64;

      runScript = "${mkZaloTree { inherit pname; }}/bin/zalo";

      profile = ''
        # Electron's setuid sandbox is unusable inside the bwrap sandbox.
        export ELECTRON_DISABLE_SANDBOX=1
        export APPIMAGE_EXTRACT_AND_RUN=1
      '';

      meta = {
        description = "Unofficial Zalo client for Linux";
        homepage = "https://github.com/doandat943/zalo-for-linux";
        license = lib.licenses.unfree;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        platforms = [ "x86_64-linux" ];
      };
    };
in
{
  inherit
    zaloDmg
    zaloWinExe
    wineTarball
    zadarkSrc
    electronSrc
    electronDist
    runtimeLibs
    nodejs
    buildTools
    zadarkBuild
    nativelibs
    dbCrossV4
    zcallBridge
    zcallRuntime
    zaloApp
    wine
    ;

  # Both variants now ship the same NixOS-capable wine (ZCALL_WINE); the
  # upstream portable bundle could not run here. `-full` is kept as an alias.
  zalo-for-linux = mkZalo { pname = "zalo-for-linux"; };
  zalo-for-linux-full = mkZalo { pname = "zalo-for-linux-full"; };
}
