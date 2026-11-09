# DMG window settings for dmgbuild (run from scripts/make-dmg.sh).
# Icon positions match Sources/DMGBackground.swift.
import os.path

app = defines["app"]            # path to Wirrow.app
assets = defines["assets"]      # folder with bg.png / bg@2x.png

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
size = None

files = [app]
symlinks = {"Applications": "/Applications"}

icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = os.path.join(assets, "bg.png")   # bg@2x.png is picked up on Retina

window_rect = ((200, 140), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
label_pos = "bottom"
arrange_by = None
icon_locations = {
    "Wirrow.app": (160, 196),
    "Applications": (480, 196),
}
