# Pinned upstream versions for the zalo-for-linux package.
#
# Everything the hermetic build fetches is pinned here. Bump these together and
# refresh the hashes (e.g. with `nix store prefetch-file --json <url>`).
{
  # Zalo for macOS (the .dmg the app is extracted from) and the matching
  # Windows installer (the call engine). The two version families usually
  # match, but they are tracked separately because they can diverge.
  zaloVersion = "26.10.10";
  zaloWinVersion = "26.10.10";

  # ZaDark dark-mode extension (git tag on quaric/zadark).
  zadarkVersion = "26.2.1";

  # Electron runtime. nixpkgs only ships 35+, and the extracted Zalo bundle
  # targets Electron 22, so the dist is fetched directly.
  electronVersion = "22.3.27";

  # Portable wine, bundled only into the "full" variant.
  wineVersion = "11.14";

  # sqlite3 N-API prebuilt (upstream uses the npm prebuilt too).
  sqlite3Version = "6.0.1";

  # ONNX Runtime, dynamically loaded by the Rust ZOCR host.
  onnxruntimeVersion = "1.30.0";

  hashes = {
    dmg = "sha256-BAUtlz/B/gAoteGSy+cnvQ98UcjRQ0V0+R2odhUIr84=";
    win = "sha256-j4BZYg+S5eGtlCNCnnnJLgkrT9MyRf+2bBlaJZlKl9c=";
    wine = "sha256-DBCCucGyqwqFZF7TyDGR3WC1V7KBaXM1Rtgf5ZmtiLM=";
    zadark = "sha256-jxtH8H4DYmW04J2wj3N2B+Tq0V+uwjIS/PSd1IISnN8=";
    electron = "sha256-Yx2OsICYxIzispQh50xprAMSseQvRF2KgFQUuhJCvzo=";
    sqlite3 = "sha256-Oyq6Bexzeu7U1oa3MJ31exyTohfI1/OgmqlSqH2wcbY=";
    onnxruntime = "sha256-pe1aPKxR+7LpDaYyrkPRkhL6qiDnZITmK8t8I92zs/0=";
  };

  # `prefetch-npm-deps` hashes for the vendored JavaScript dependency trees.
  npmHashes = {
    # nix/tools/package-lock.json — asar + fs-extra + node-html-parser.
    tools = "sha256-fjyJl09TxXcwHC2E3TBAn8EgsEyy+xhT/7r7CFAJQ9I=";
    # nix/zadark-package-lock.json — ZaDark's gulp toolchain.
    zadark = "sha256-ocn0WLvN62hdYk/C0TbGxmzbFlFN/KnOxOI8c/d3yUM=";
  };
}
