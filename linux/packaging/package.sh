#!/usr/bin/env bash
# packages a built Linux bundle three ways:
#   OSCSlider-linux-x64.tar.gz  - portable folder (run ./oscslider, or ./install.sh)
#   OSCSlider-x86_64.AppImage   - single portable file, no install needed
#   oscslider_<version>_amd64.deb - Debian/Ubuntu package
#
# usage: package.sh <bundle dir> <version> <output dir>
# needs appimagetool on PATH (or APPIMAGETOOL=/path/to/it) and dpkg-deb.
set -euo pipefail

bundle="$(cd "$1" && pwd)"
version="$2"
out="$(mkdir -p "$3" && cd "$3" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
id="com.estrogencat.oscslider"
appimagetool="${APPIMAGETOOL:-appimagetool}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- tarball ---
stage="$work/OSCSlider-linux-x64"
mkdir -p "$stage"
cp -r "$bundle/." "$stage/"
cp "$here/install.sh" "$here/$id.desktop" "$stage/"
chmod +x "$stage/install.sh" "$stage/oscslider"
tar -C "$work" -czf "$out/OSCSlider-linux-x64.tar.gz" "OSCSlider-linux-x64"

# --- AppImage ---
appdir="$work/OSCSlider.AppDir"
mkdir -p "$appdir/usr/lib/oscslider" "$appdir/usr/share/metainfo"
cp -r "$bundle/." "$appdir/usr/lib/oscslider/"
cp "$here/$id.desktop" "$appdir/$id.desktop"
cp "$here/oscslider.png" "$appdir/$id.png"
cp "$here/$id.metainfo.xml" "$appdir/usr/share/metainfo/$id.appdata.xml"
cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/oscslider/oscslider" "$@"
RUN
chmod +x "$appdir/AppRun"
# --appimage-extract-and-run so it also works where FUSE isn't available (CI).
ARCH=x86_64 VERSION="$version" "$appimagetool" --appimage-extract-and-run --no-appstream \
  "$appdir" "$out/OSCSlider-x86_64.AppImage"

# --- .deb ---
# Debian versions can't contain "-" in the upstream part; "~" sorts a
# pre-release before the final release, which is what we want.
debver="${version//-/\~}"
root="$work/deb"
mkdir -p "$root/DEBIAN" "$root/opt/oscslider" "$root/usr/bin" \
  "$root/usr/share/applications" "$root/usr/share/icons/hicolor/256x256/apps" "$root/usr/share/metainfo"
cp -r "$bundle/." "$root/opt/oscslider/"
ln -s /opt/oscslider/oscslider "$root/usr/bin/oscslider"
sed "s|^Exec=.*|Exec=/opt/oscslider/oscslider|" "$here/$id.desktop" > "$root/usr/share/applications/$id.desktop"
cp "$here/oscslider.png" "$root/usr/share/icons/hicolor/256x256/apps/$id.png"
cp "$here/$id.metainfo.xml" "$root/usr/share/metainfo/"
size="$(du -sk "$root" | cut -f1)"
cat > "$root/DEBIAN/control" <<CONTROL
Package: oscslider
Version: $debver
Architecture: amd64
Maintainer: Hazel Rane <hazel@softgaypaws.com>
Installed-Size: $size
Depends: libgtk-3-0 | libgtk-3-0t64, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, gstreamer1.0-plugins-good
Section: utils
Priority: optional
Homepage: https://github.com/estrogencat/OSCSlider
Description: control VRChat avatar parameters over OSC
 Sliders, toggles, automations and sequences for VRChat avatar parameters,
 with automatic parameter discovery over OSCQuery.
CONTROL
find "$root" -type d -exec chmod 755 {} +
dpkg-deb --root-owner-group --build "$root" "$out/oscslider_${debver}_amd64.deb" >/dev/null

ls -la "$out"
