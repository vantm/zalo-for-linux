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
