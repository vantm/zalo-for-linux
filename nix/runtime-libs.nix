# Runtime libraries shared by the dev-shell FHS and the packaged FHS wrapper.
#
# Keeping a single list means `nix develop` and `./result/bin/zalo` run in the
# same environment: Electron/Chromium dlopen far more than their ELF DT_NEEDED
# graph (GL, GIO, GStreamer, GTK modules, ...), so the FHS must carry the whole
# set. A plain RPATH derivation starts Electron but its helper processes fail to
# launch and no window appears.
{ pkgs }:
let
  inherit (pkgs) lib;
  isX86_64 = pkgs.stdenv.hostPlatform.isx86_64;
in
{
  # Host-architecture Electron / Chromium / GTK runtime libraries.
  electronLibs = with pkgs; [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    fuse3
    gdk-pixbuf
    glib
    gtk3
    harfbuzz
    krb5
    libdrm
    libGL
    libgbm
    libappindicator-gtk3
    libnotify
    libX11
    libXcomposite
    libXcursor
    libXdamage
    libXext
    libXfixes
    libXi
    libXrandr
    libXrender
    libxcb
    libxkbcommon
    libxshmfence
    libXtst
    mesa
    nspr
    nss
    pango
    pulseaudio
    systemd
    util-linux
  ];

  # 32-bit counterparts, used by the 32-bit pieces of the call bridge
  # (streamproxy.so) and by 32-bit guests.
  multiLibs =
    p:
    lib.optionals isX86_64 [
      p.alsa-lib
      p.expat
      p.fontconfig
      p.freetype
      p.glib
      p.libdrm
      p.libGL
      p.libX11
      p.libXi
      p.libXext
      p.libXrandr
      p.libXrender
      p.libxcb
      p.mesa
      p.pulseaudio
      p.zlib
    ];
}
