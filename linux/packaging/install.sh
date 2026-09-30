#!/usr/bin/env sh
# installs OSCSlider for the current user: the app into ~/.local/share,
# a launcher into ~/.local/bin, and a menu entry + icon. run it from the
# extracted release folder. pass --uninstall to remove it again.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
app_dir="$data/oscslider"
bin_dir="$HOME/.local/bin"
desktop="$data/applications/com.estrogencat.oscslider.desktop"
icon="$data/icons/hicolor/256x256/apps/com.estrogencat.oscslider.png"

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$app_dir" "$bin_dir/oscslider" "$desktop" "$icon"
  echo "OSCSlider removed. Settings are kept in ${XDG_CONFIG_HOME:-$HOME/.config}/OSCSlider."
  exit 0
fi

rm -rf "$app_dir"
mkdir -p "$app_dir" "$bin_dir" "$(dirname "$desktop")" "$(dirname "$icon")"
cp -r "$here/oscslider" "$here/lib" "$here/data" "$app_dir/"
ln -sf "$app_dir/oscslider" "$bin_dir/oscslider"
cp "$here/data/oscslider.png" "$icon"
sed "s|^Exec=.*|Exec=$app_dir/oscslider|" "$here/com.estrogencat.oscslider.desktop" > "$desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data/applications" || true

echo "OSCSlider installed. Launch it from your app menu, or run: oscslider"
