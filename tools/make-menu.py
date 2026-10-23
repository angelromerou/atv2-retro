"""Generates the Apple TV main-menu entries (appliance plist + icons) for our apps, and the
Info.plist of each console app. Needs Pillow: python tools/make-menu.py

Each app gets <App>.app/ATVMenu/{<key>.appliance, <key with . -> _>@720.png (ATV2), ...@1080.png (ATV3)}, and the consoles in
SHELF_LOGOS also a top-shelf logo (they sit in the top row; the rest go in the grid). tools/deploy.sh copies
those into AppleTV.app, where the ATVLaunch tweak turns them into menu items (see atvlaunch/Tweak.m).
Console apps are Retro (apps/retro) + one libretro core; tools/build-consoles.sh fills in the binaries.
"""
import math
import os
import plistlib

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
S = 4  # supersampling

# name, bundle dir, bundle id, sunburst rgb, glyph, menu order (Computers = 5, Settings = 6), console info
APPS = [
    ("Doom", "apps/doom/Doom.app", "com.atvdev.doom", (85, 25, 18), "doom", 5.1, None),
    ("NES", "apps/consoles/NES.app", "com.atvdev.nes", (190, 40, 45), "nes", 5.2,
     dict(core="fceumm", system="nes", title="NES", exts=["nes", "fds", "unf", "unif"])),
    ("SNES", "apps/consoles/SNES.app", "com.atvdev.snes", (105, 70, 190), "snes", 5.3,
     dict(core="snes9x2010", system="snes", title="Super Nintendo", exts=["sfc", "smc"])),
    ("Game Boy", "apps/consoles/GameBoy.app", "com.atvdev.gb", (60, 140, 50), "gb", 5.4,
     dict(core="gambatte", system="gb", title="Game Boy", exts=["gb", "gbc"])),
    ("GBA", "apps/consoles/GBA.app", "com.atvdev.gba", (50, 70, 175), "gba", 5.5,
     dict(core="gpsp", system="gba", title="Game Boy Advance", exts=["gba"])),
    ("Genesis", "apps/consoles/Genesis.app", "com.atvdev.md", (70, 70, 80), "md", 5.35,
     dict(core="picodrive", system="md", title="Genesis", exts=["md", "gen", "smd", "bin"])),
    ("Controllers", "apps/controllers/Controllers.app", "com.atvdev.controllers", (25, 125, 145), "pad", 5.05, None),
]

# consoles whose logo (a Wikimedia Commons render in downloads/logos/<kind>.png) fills the top shelf
SHELF_LOGOS = ("nes", "snes", "md", "gb", "gba")
SHELF_SIZE = (1280, 378)  # the shelf's frame; the logo control is stretched to it


SAVER_SIZE = (1584, 1188)  # the stock screensaver photos' size (AppleTV.app/DefaultNaturePhotos)


def logo_on_floor(kind, size, floor, scale=1):
    """The console's logo standing on a floor at y = floor, with a fading reflection, on a transparent canvas."""
    logo = Image.open(os.path.join(ROOT, "downloads", "logos", kind + ".png")).convert("RGBA")
    logo = logo.crop(logo.getbbox())
    w, h = logo.size
    k = scale * min(math.sqrt(50000 / (w * h)), 600 / w, 140 / h)  # similar ink for wide and tall logos
    logo = logo.resize((round(w * k), round(h * k)), Image.LANCZOS)
    W, H = size
    x = (W - logo.width) // 2
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    out.alpha_composite(logo, (x, floor - logo.height))
    refl = logo.transpose(Image.FLIP_TOP_BOTTOM)
    fade = Image.linear_gradient("L").resize(refl.size).point(lambda v: int((255 - v) * 0.3))
    refl.putalpha(Image.composite(fade, Image.new("L", refl.size, 0), refl.getchannel("A")))
    out.alpha_composite(refl.crop((0, 0, refl.width, min(refl.height, H - floor - 2))), (x, floor + 2))
    return out


def shelf_logo(kind, path):
    """The logo stands on the shelf's floor where Apple's logo does."""
    logo_on_floor(kind, SHELF_SIZE, 270).save(path)


def saver_photo(kind, rgb, path):
    """A screensaver photo: the top-shelf look (logo on a light gray floor) over a band in the console's color."""
    W, H = SAVER_SIZE
    out = Image.linear_gradient("L").resize(SAVER_SIZE).point(lambda v: 235 - v * 70 // 255).convert("RGBA")
    ImageDraw.Draw(out).rectangle((0, H - 110, W, H), fill=rgb)
    out.alpha_composite(logo_on_floor(kind, SAVER_SIZE, 700, 2))
    out.convert("RGB").save(path, quality=90)


# ---- glyphs: white shapes with holes, drawn on a W x H "L" mask at 4x ----

def holes_dpad(d, x, y, r):
    d.rectangle((x - r, y - r * 0.34, x + r, y + r * 0.34), fill=0)
    d.rectangle((x - r * 0.34, y - r, x + r * 0.34, y + r), fill=0)


def circle(d, x, y, r, fill=0):
    d.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def glyph(kind, W, H):
    g = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(g)
    cx, cy = W / 2, H * 0.47
    if kind == "pad":  # gamepad with wireless arcs
        gw, gh = 96 * S, 42 * S
        cy += 6 * S
        d.rounded_rectangle((cx - gw / 2, cy - gh / 2, cx + gw / 2, cy + gh / 2), radius=gh / 2, fill=255)
        for sx in (-1, 1):
            d.ellipse((cx + sx * gw * 0.33 - 15 * S, cy - 4 * S, cx + sx * gw * 0.33 + 15 * S, cy + 30 * S), fill=255)
        holes_dpad(d, cx - gw * 0.27, cy - 2 * S, 10 * S)
        for ox, oy in ((0, -8), (0, 8), (-8, 0), (8, 0)):
            circle(d, cx + gw * 0.27 + ox * S, cy - 2 * S + oy * S, 4 * S)
        for i, r in enumerate((10, 17, 24)):  # waves above
            d.arc((cx - r * S, cy - gh / 2 - 8 * S - r * S, cx + r * S, cy - gh / 2 - 8 * S + r * S), 225, 315, fill=255, width=3 * S)
    elif kind == "nes":  # NES controller: flat rectangle, d-pad, select/start, two round buttons
        gw, gh = 112 * S, 46 * S
        d.rounded_rectangle((cx - gw / 2, cy - gh / 2, cx + gw / 2, cy + gh / 2), radius=5 * S, fill=255)
        holes_dpad(d, cx - gw * 0.32, cy + 2 * S, 11 * S)
        for ox in (-7, 7):
            d.rounded_rectangle((cx + ox * S - 6 * S, cy + 4 * S, cx + ox * S + 6 * S, cy + 9 * S), radius=2 * S, fill=0)
        for ox in (25, 41):
            circle(d, cx + ox * S, cy + 4 * S, 6.5 * S)
    elif kind == "snes":  # SNES "dog bone": pill body, d-pad, diamond of four buttons
        gw, gh = 118 * S, 50 * S
        d.rounded_rectangle((cx - gw / 2, cy - gh / 2, cx + gw / 2, cy + gh / 2), radius=gh / 2, fill=255)
        holes_dpad(d, cx - gw * 0.30, cy, 11 * S)
        for ox, oy in ((0, -10), (0, 10), (-10, 0), (10, 0)):
            circle(d, cx + gw * 0.30 + ox * S, cy + oy * S, 5 * S)
        for ox in (-7, 7):
            d.rounded_rectangle((cx + ox * S - 6 * S, cy + 2 * S, cx + ox * S + 6 * S, cy + 7 * S), radius=2.5 * S, fill=0)
    elif kind == "gb":  # original Game Boy: portrait, big screen, d-pad, two buttons
        gw, gh = 56 * S, 84 * S
        x0, y0 = cx - gw / 2, cy - gh / 2 + 2 * S
        d.rounded_rectangle((x0, y0, x0 + gw, y0 + gh), radius=6 * S, fill=255)
        d.pieslice((x0 + gw - 26 * S, y0 + gh - 26 * S, x0 + gw, y0 + gh), 0, 90, fill=0)  # rounded corner cut
        d.rectangle((x0 + gw - 13 * S, y0 + gh - 26 * S, x0 + gw, y0 + gh - 13 * S), fill=255)
        d.rectangle((x0 + gw - 26 * S, y0 + gh - 13 * S, x0 + gw - 13 * S, y0 + gh), fill=255)
        d.pieslice((x0 + gw - 26 * S, y0 + gh - 26 * S, x0 + gw, y0 + gh), 0, 90, fill=255)
        d.rounded_rectangle((x0 + 7 * S, y0 + 7 * S, x0 + gw - 7 * S, y0 + 41 * S), radius=3 * S, fill=0)
        holes_dpad(d, x0 + 16 * S, y0 + 60 * S, 7 * S)
        circle(d, x0 + 36 * S, y0 + 63 * S, 4 * S); circle(d, x0 + 46 * S, y0 + 57 * S, 4 * S)
    elif kind == "gba":  # GBA: wide body, screen in the middle, d-pad left, two buttons right
        gw, gh = 124 * S, 56 * S
        d.rounded_rectangle((cx - gw / 2, cy - gh / 2, cx + gw / 2, cy + gh / 2), radius=gh / 2.2, fill=255)
        d.rounded_rectangle((cx - 28 * S, cy - 19 * S, cx + 28 * S, cy + 19 * S), radius=3 * S, fill=0)
        holes_dpad(d, cx - 45 * S, cy - 2 * S, 8 * S)
        circle(d, cx + 40 * S, cy + 3 * S, 4.5 * S); circle(d, cx + 50 * S, cy - 5 * S, 4.5 * S)
    elif kind == "md":  # Genesis 3-button pad: rounded body, round d-pad, slanted row of three buttons
        gw, gh = 116 * S, 54 * S
        d.rounded_rectangle((cx - gw / 2, cy - gh / 2, cx + gw / 2, cy + gh / 2), radius=gh / 2, fill=255)
        circle(d, cx - 32 * S, cy, 15 * S)
        circle(d, cx - 32 * S, cy, 12 * S, fill=255)
        holes_dpad(d, cx - 32 * S, cy, 9 * S)
        for i in range(3):
            circle(d, cx + (14 + i * 12) * S, cy + (6 - i * 5) * S, 5.5 * S)
        d.rounded_rectangle((cx - 6 * S, cy - 14 * S, cx + 6 * S, cy - 9 * S), radius=2.5 * S, fill=0)  # start
    elif kind == "doom":  # bold title text
        fonts = ["C:/Windows/Fonts/arialbd.ttf", "/mnt/c/Windows/Fonts/arialbd.ttf",  # Windows, WSL
                 "/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]
        font = ImageFont.truetype(next(f for f in fonts if os.path.exists(f)), 46 * S)
        box = d.textbbox((0, 0), "DOOM", font=font)
        d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]), "DOOM", font=font, fill=255)
    return g


def icon(rgb, kind, base):
    W, H = 188 * S, 108 * S
    inner = (3 * S, 2 * S, W - 3 * S, H - 4 * S)  # tile inside the drop shadow, like Apple's icons
    bg = Image.new("RGB", (W, H))
    px = bg.load()
    cx, cy = W / 2, H * 0.42
    for y in range(H):
        for x in range(W):
            dist = math.hypot((x - cx) / W, (y - cy) / H) * 1.6
            ray = 0.06 * (math.cos(math.atan2(y - cy, x - cx) * 36) + 1) * max(0, 1 - dist)
            k = 1.15 - 0.65 * min(1, dist) + 0.5 * ray  # bright center fading out, faint rays
            px[x, y] = tuple(max(0, min(255, int(c * k))) for c in rgb)
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle(inner, radius=9 * S, fill=255)
    tile = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    tile.paste(bg, (0, 0), mask)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((inner[0], inner[1] + 2 * S, inner[2], inner[3] + 2 * S), radius=9 * S, fill=(0, 0, 0, 140))
    out = Image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(2 * S)), tile)
    out = Image.composite(Image.new("RGBA", (W, H), (255, 255, 255, 255)), out, glyph(kind, W, H))
    out.resize((188, 108), Image.LANCZOS).save(base + "@720.png")
    out.resize((282, 159), Image.LANCZOS).save(base + "@1080.png")  # ATV3: 1080p menu, Apple's tile size


def main():
    saver = os.path.join(ROOT, "build", "screensaver")  # tools/install-system.sh puts these in place of the stock photos
    os.makedirs(saver, exist_ok=True)
    for name, bundle, bundle_id, rgb, kind, order, console in APPS:
        bundle = os.path.join(ROOT, bundle)
        menu = os.path.join(bundle, "ATVMenu")
        os.makedirs(menu, exist_ok=True)
        key = "com.atvdev.appliance." + bundle_id.split(".")[-1]
        shelf = {}
        if kind in SHELF_LOGOS:
            shelf = {"ATVDEVTopRow": True, "ATVDEVShelfImage": key.replace(".", "_") + "_shelf.png"}
            shelf_logo(kind, os.path.join(menu, shelf["ATVDEVShelfImage"]))
            saver_photo(kind, rgb, os.path.join(saver, kind + ".jpg"))
        plistlib.dump({
            "FRApplianceIdentifier": key,
            "FRApplianceLocalizableNameKey": name,  # no strings table, so the key itself is the title
            "FRLocalizableStringsFileName": "ATVDevLocalizable",
            "FRAppliancePreferedOrderValue": order,
            "FRPrincipalClass": "ATVDEVAppAppliance",
            "FRRemoteAppliance": True,
            "FRApplianceCategoryDescriptors": [],
            "FRHideIfNoCategories": False,
            "ATVDEVLaunchID": bundle_id,
            **shelf,
        }, open(os.path.join(menu, key + ".appliance"), "wb"))
        icon(rgb, kind, os.path.join(menu, key.replace(".", "_")))
        if console:
            plistlib.dump({
                "CFBundleExecutable": "Retro",
                "CFBundleIdentifier": bundle_id,
                "CFBundleName": name,
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1.0",
                "UIInterfaceOrientation": "UIInterfaceOrientationLandscapeRight",
                "UIStatusBarHidden": True,
                "UIDeviceFamily": [1, 3],             # 3 = Apple TV: the ATV3 (iOS 8) refuses to launch apps without it
                "RetroCore": console["core"],         # core.dylib in the bundle is built from this core
                "RetroSystem": console["system"],     # ROM folder under /var/mobile/Media/ROMs
                "RetroTitle": console["title"],
                "RetroExtensions": console["exts"],
                "RetroColor": "#%02x%02x%02x" % rgb,
            }, open(os.path.join(bundle, "Info.plist"), "wb"))
        print("menu item:", name)


if __name__ == "__main__":
    main()
