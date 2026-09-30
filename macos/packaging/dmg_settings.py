# dmgbuild settings for the OSCSlider disk image - the classic "drag the app
# onto Applications" window. used by the release workflow:
#   dmgbuild -s macos/packaging/dmg_settings.py -D app=path/to/OSCSlider.app \
#     -D background=path/to/background.tiff "OSCSlider" OSCSlider-macos.dmg
import os.path

application = defines.get("app", "OSCSlider.app")  # noqa: F821 (dmgbuild provides defines)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [appname]

background = defines.get("background", "builtin-arrow")  # noqa: F821
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
# centres match the arrow and labels drawn into dmg-background.png.
icon_locations = {
    appname: (170, 190),
    "Applications": (490, 190),
}
