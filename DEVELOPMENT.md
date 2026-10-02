# Development

This document covers building Zalo for Linux from source, including the
toolchain, scripts, and how to add new patches or native addons.

For an overview of how the project works, see
[ARCHITECTURE.md](./ARCHITECTURE.md). For info on the native addons
reimplementation, see [nativelibs/README.md](./nativelibs/README.md).

## Prerequisites

- Linux x86_64
- Node.js and npm
- `7z` (`p7zip-full`) for extracting the macOS app
- C++ build tools for native addons (see [nativelibs/README.md](./nativelibs/README.md#requirements))

On Debian/Ubuntu:

```bash
sudo apt-get update && sudo apt-get install -y p7zip-full build-essential libssl-dev liblzma-dev
```

## Nix / NixOS

A flake provides the whole toolchain, so no host packages are needed. It works
on any Linux with flakes enabled, and is the recommended path on NixOS.

```bash
nix develop          # full environment (FHS sandbox)
# or, with direnv installed:
direnv allow
```

Inside the shell everything from the prerequisites list is already available:
Node 22, Rust (pinned), `7z`, gcc/g++, the i686 mingw cross compiler, zsync,
plus the 32-bit toolchain and wine needed by the call bridge.

There are two shells:

| Shell | Command | Use |
|-------|---------|-----|
| `default` | `nix develop` | Build and run the app. Wraps everything in an FHS sandbox so Electron 22, electron-builder and appimagetool (prebuilt glibc binaries) run on NixOS, and so 32-bit wine works. |
| `light` | `nix develop .#light` | Plain shell for editing, `cargo`, and native addon builds. No FHS sandbox — Electron and AppImage packaging will not run here. |

Then the usual workflow applies:

```bash
npm ci
npm run main            # setup + build, output in dist/
npm start               # run the app from the extracted app/ directory
```

Notes:

- `nix develop -c <cmd>` runs a single command in the **light** shell, e.g.
  `nix develop .#light -c npm ci`. It does not work in the FHS shell: the
  sandbox entry point `exec`s the shell, so the command never reaches it. Use
  the runnable wrapper there instead — `nix run .#fhs -- -c 'npm ci'`.
- The shell exports `APPIMAGE_EXTRACT_AND_RUN=1` (run AppImages without FUSE)
  and `ELECTRON_DISABLE_SANDBOX=1` (the Chromium sandbox cannot be nested inside
  the FHS bubblewrap sandbox).
- The first build downloads the Zalo DMG, the Windows installer and Electron
  headers, so it needs network access.
- `nix fmt` formats the Nix files (`nixfmt`).
- On aarch64 the mingw/32-bit pieces are omitted, matching CI.

## Packaging (`nix build`)

The flake also builds the app from source into a runnable x86_64 package:

```bash
nix build .#zalo-for-linux        # ZaDark integration
nix build .#zalo-for-linux-full   # ZaDark + bundled portable wine
./result/bin/zalo
```

Unlike `npm run main`, the Nix build is hermetic — **nothing is downloaded
while building**. Every upstream artifact is a fixed-output derivation pinned in
[`nix/versions.nix`](./nix/versions.nix) (the macOS DMG, the Windows installer,
Electron 22, portable wine, ZaDark, the sqlite3 N-API prebuilt), and every
JavaScript and Rust dependency is vendored.

The pipeline in [`nix/package.nix`](./nix/package.nix) mirrors the upstream one:

1. `7z` + `@electron/asar` extract `app.asar` and the upstream patch scripts in
   `scripts/patches/` are run unmodified. Their in-place compiler calls are
   neutralised with no-op shims because the native addons are built separately.
2. Native addons are built as their own derivations — the five Rust crates via
   `rustPlatform` and `db-cross-v4` compiled directly from `binding.gyp` inputs.
3. `streamproxy.so` (32-bit, `gcc_multi` + i686 X headers) and `pipebridge.exe`
   (i686 mingw + mcfgthread) are compiled, and the ZaloCall Qt runtime is
   extracted from the Windows installer.
4. electron-builder and quick-sharun are **not** used. The app is laid out by
   hand (Electron 22 dist + `resources/app` + `app/` + `zcall-bridge/`) and
   wrapped for NixOS with `autoPatchelf`/`makeWrapper`.
5. That tree is then wrapped in `pkgs.buildFHSEnv` (`mkZalo`), so
   `result/bin/zalo` runs **outside** `nix develop`. Chromium launches its
   helper processes (zygote/GPU/renderer) by `dlopen`-ing libraries and shelling
   out against a full filesystem view; a plain RPATH derivation starts Electron
   but never shows a window. `nix/runtime-libs.nix` is the single source of
   truth for the library set shared by the dev shell and the package FHS. The
   FHS output also installs a freedesktop entry and icon under `share/`
   (`makeDesktopItem` + the app's `favicon-512x512.png`), so the app shows up in
   menu launchers; `Exec` points at the sandboxed `bin/zalo`. Zalo's own "start
   with system" writes an XDG autostart entry; the FHS exports
   `ZALO_LINUX_LAUNCHER` (consumed by `scripts/patches/patch-auto-launch.js`) so
   that entry points back at the FHS wrapper instead of the bare store Electron,
   which cannot start Chromium's helpers.

The call engine runs under `pkgs.wineWow64Packages.stable`, exposed to the app
as `ZCALL_WINE` (its highest-priority wine). The upstream portable Kron4ek wine
needs 32-bit host libraries that NixOS does not provide, so it is not used here;
the wow64 build runs the 32-bit `ZaloCall.exe`/`pipebridge.exe` under a 64-bit
host.

> The package bundles proprietary Zalo code extracted from the vendored DMG, so
> it is marked `unfree`. The flake sets `config.allowUnfree = true` in its own
> package set; consumers of the output need to allow unfree too.

To bump a version: update `nix/versions.nix` and refresh the affected hashes with
`nix store prefetch-file --json <url>` (or `nix run nixpkgs#prefetch-npm-deps --
<npm-lock>` for the npm trees). The ZaDark manifest/lock under `nix/` exist only
because `plugins/zadark` is a submodule; they pin that submodule's dependency
closure.

## Quick Start

```bash
# Clone
git clone https://github.com/doandat943/zalo-for-linux.git
cd zalo-for-linux

# Init submodules (ZaDark, etc.)
git submodule update --init --recursive

# Setup + build (downloads DMG, extracts, patches, packages)
npm run main
```

Output: `dist/Zalo-<version>.AppImage`

## Two-Phase Build

You can run setup and build separately:

```bash
# Phase 1: download + extract (writes to app/ and temp/)
npm run main:setup

# Phase 2: package into AppImage (uses app/)
npm run main:build
```

## Development Scripts

| Command | Description |
|---------|-------------|
| `npm run main:setup` | `SETUP=true node scripts/main.js` (check + download + prepare) |
| `npm run main:build` | `BUILD=true node scripts/main.js` (build AppImage) |
| `npm run start` | Run the app in development mode (after setup) |
| `npm run build` | Build AppImage only (calls `scripts/build.js`) |
| `npm run download-dmg` | Download Zalo DMG |
| `npm run prepare-app` | Extract Zalo DMG and apply Linux patches |
| `npm run prepare-zadark` | Build ZaDark dark-mode assets |

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `ZALO_VERSION` | Specify exact Zalo version to download/extract | `ZALO_VERSION="25.11.20"` |
| `ZADARK_VERSION` | Specify exact ZaDark version to download/integrate | `ZADARK_VERSION="v8.3.4"` |
| `FORCE_DOWNLOAD` | Force re-download even if file exists | `FORCE_DOWNLOAD=true` |

## Versioned Mode Example

```bash
# Download a specific Zalo version
ZALO_VERSION="25.8.2" npm run download-dmg

# Extract that specific version
ZALO_VERSION="25.8.2" npm run prepare-app

# Force re-download even if cached
FORCE_DOWNLOAD=true npm run download-dmg
```

## Interactive DMG Selection

If multiple DMG files exist in `temp/`, `npm run prepare-app` shows an
interactive menu:

```
📋 Available DMG files:
   Use ↑↓ arrow keys to navigate, Enter to select, Esc to cancel

  ● ZaloSetup-universal-26.1.0.dmg
    Version: v26.1.0 | Size: 198.5MB | Date: 12/20/2024, 3:45:12 PM

  ○ ZaloSetup-universal-25.8.2.dmg
    Version: v25.8.2 | Size: 195.2MB | Date: 12/15/2024, 10:23:45 AM
```

A single DMG is auto-selected.

## Adding a New Patch

Patches live in `scripts/patches/` as individual files. To add a new patch:

1. Create `scripts/patches/patch-<name>.js`:

```javascript
const fs = require('fs-extra');
const path = require('path');

const APP_DIR = path.join(__dirname, '..', '..', 'app');

async function main() {
  console.log('🔧 Patching...');

  const targetPath = path.join(APP_DIR, 'main-dist', 'main.js');
  if (!fs.existsSync(targetPath)) {
    console.log('⚠️  File not found, skipping');
    return;
  }

  let content = fs.readFileSync(targetPath, 'utf8');
  if (content.includes('OLD_PATTERN')) {
    content = content.replace(/OLD_PATTERN/g, 'NEW_PATTERN');
    fs.writeFileSync(targetPath, content, 'utf8');
    console.log('✅ Applied my-patch');
  }
}

module.exports = { main };
```

2. Add to `scripts/prepare-app.js`:

```javascript
const { main: patchName } = require('./patches/patch-<name>');
await patchName();
```

Always check for the expected pattern before replacing — Zalo versions change, and patterns may shift.

## Debugging the Extracted App

- **DevTools**: Press `Ctrl+Shift+I` in the Zalo window
- **Tray menu**: Right-click the tray icon → "Toggle DevTools"
- **Logs**: Check `~/.config/Zalo/logs/` or run with `ELECTRON_ENABLE_LOGGING=1`

## Plugin Development

The project supports plugins under `plugins/`:

- `zadark/` — Dark mode extension (git submodule from
  [quaric/zadark](https://github.com/quaric/zadark))
- `zalux/` — Linux UX improvements (screenshot button, etc.)

Each plugin is loaded in `main.js`. See existing plugins for examples.
