"""Generate Conduit's app icon into an Xcode asset catalog.

Runs on Windows (Pillow only), so the icon is authorable without a Mac. The
build script re-runs this on the CI runner, which keeps the committed PNG and
the generator from drifting apart.

The motif is the app itself: a glass capsule with a stream passing through it.
A conduit is a channel, and the command bar is the channel.
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "App" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

MASTER = 1024

# Deep indigo ground so the capsule and the stream both read at 40px, where
# most icons are actually seen.
BG_TOP = (22, 20, 48)
BG_BOTTOM = (10, 14, 32)
GLOW = (96, 132, 255)
CAPSULE_FILL = (255, 255, 255, 30)
CAPSULE_EDGE = (206, 220, 255, 190)
STREAM_HOT = (150, 224, 255)
STREAM_COOL = (128, 120, 255)


def vertical_gradient(size, top, bottom):
    gradient = Image.new("RGB", (1, size), top)
    pixels = gradient.load()
    for y in range(size):
        t = y / max(1, size - 1)
        pixels[0, y] = (
            round(top[0] + (bottom[0] - top[0]) * t),
            round(top[1] + (bottom[1] - top[1]) * t),
            round(top[2] + (bottom[2] - top[2]) * t),
        )
    return gradient.resize((size, size), Image.BILINEAR)


def draw_icon(size=MASTER):
    s = size / MASTER
    img = vertical_gradient(size, BG_TOP, BG_BOTTOM).convert("RGBA")

    # Soft radial glow behind the capsule, drawn oversized then blurred so the
    # falloff is smooth rather than banded.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        [size * 0.10, size * 0.25, size * 0.90, size * 0.75],
        fill=GLOW + (120,),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=int(90 * s)))
    img = Image.alpha_composite(img, glow)

    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)

    # The capsule: the command bar, centred and generously inset so it survives
    # the rounded-rect mask iOS applies.
    cap_left, cap_right = size * 0.175, size * 0.825
    cap_top, cap_bottom = size * 0.375, size * 0.625
    radius = (cap_bottom - cap_top) / 2
    d.rounded_rectangle(
        [cap_left, cap_top, cap_right, cap_bottom],
        radius=radius,
        fill=CAPSULE_FILL,
        outline=CAPSULE_EDGE,
        width=max(2, int(9 * s)),
    )

    # The stream: a tapering bar of light running through the capsule, brighter
    # at the leading edge to imply direction.
    stream_top = size * 0.466
    stream_bottom = size * 0.534
    stream_left = size * 0.262
    stream_right = size * 0.635
    steps = 64
    for i in range(steps):
        t0 = i / steps
        t1 = (i + 1) / steps
        x0 = stream_left + (stream_right - stream_left) * t0
        x1 = stream_left + (stream_right - stream_left) * t1 + 1
        colour = (
            round(STREAM_COOL[0] + (STREAM_HOT[0] - STREAM_COOL[0]) * t0),
            round(STREAM_COOL[1] + (STREAM_HOT[1] - STREAM_COOL[1]) * t0),
            round(STREAM_COOL[2] + (STREAM_HOT[2] - STREAM_COOL[2]) * t0),
            255,
        )
        inset = (1 - t0) * (stream_bottom - stream_top) * 0.16
        d.rectangle([x0, stream_top + inset, x1, stream_bottom - inset], fill=colour)

    # Arrowhead at the leading edge, completing the "send" reading.
    tip_x = size * 0.755
    mid_y = (stream_top + stream_bottom) / 2
    half = size * 0.063
    d.polygon(
        [
            (stream_right - size * 0.005, mid_y - half),
            (tip_x, mid_y),
            (stream_right - size * 0.005, mid_y + half),
        ],
        fill=STREAM_HOT + (255,),
    )

    # Specular highlight along the capsule's upper edge, which is what makes
    # the shape read as glass rather than as an outlined pill.
    highlight = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hd.rounded_rectangle(
        [cap_left + 12 * s, cap_top + 8 * s, cap_right - 12 * s, cap_top + radius * 0.75],
        radius=radius * 0.6,
        fill=(255, 255, 255, 46),
    )
    highlight = highlight.filter(ImageFilter.GaussianBlur(radius=int(14 * s)))

    overlay = Image.alpha_composite(overlay, highlight)
    return Image.alpha_composite(img, overlay).convert("RGB")


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    icon = draw_icon(MASTER)
    icon.save(OUT / "icon-1024.png")

    # A single 1024 entry is sufficient from Xcode 14 onward; the toolchain
    # downsamples every other size at build time.
    contents = {
        "images": [
            {
                "filename": "icon-1024.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (OUT / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")

    # The catalog root needs its own Contents.json or xcodebuild warns.
    root = OUT.parent
    (root / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )

    print(f"wrote {OUT / 'icon-1024.png'} ({MASTER}x{MASTER})")
    print(f"wrote {OUT / 'Contents.json'}")


if __name__ == "__main__":
    main()
