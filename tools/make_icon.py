"""Draw the addon icon (Media/Icon.tga): AIQ on a dark square, the A in white and IQ in the theme
colour, as the minimap button draws it. The game can't tint the addon list's icon, so the colour is
baked in: pass a hex colour to match your ElvUI/ToxiUI accent (default AuctionIQ's brand blue).

    python3 tools/make_icon.py [rrggbb]
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONT = "/usr/share/fonts/opentype/inter/Inter-Black.otf"
S = 128


def draw(accent):
    acc = tuple(int(accent[i:i + 2], 16) for i in (0, 2, 4)) + (255,)
    im = Image.new("RGBA", (S, S), (26, 26, 26, 255))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, S - 1, S - 1], outline=(0, 0, 0, 255), width=4)
    font = ImageFont.truetype(FONT, 50)
    a_w = d.textlength("A", font=font)
    iq_w = d.textlength("IQ", font=font)
    x = (S - (a_w + iq_w)) / 2
    top, bottom = font.getbbox("AIQ")[1], font.getbbox("AIQ")[3]
    y = (S - (bottom - top)) / 2 - top
    d.text((x, y), "A", font=font, fill=(242, 242, 242, 255))
    d.text((x + a_w, y), "IQ", font=font, fill=acc)
    return im


if __name__ == "__main__":
    accent = (sys.argv[1] if len(sys.argv) > 1 else "3fc7eb").lstrip("#")
    draw(accent).save(ROOT / "Media" / "Icon.tga")
    print("wrote Media/Icon.tga with IQ in #" + accent)
