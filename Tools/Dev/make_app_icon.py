"""Generates the app icon, an Icon Composer document (App/Resources/AppIcon.icon).

The mark is a miniature of the app's transcript, in the app's palette (Theme) and font: your prompt
as a filled bubble at the trailing side, above two outlined response cards. Each card has a header
row with its lane badge (A or B, set in Departure Mono, in a ring), a divider and lines of text.
Layers are SVG on the 1024 pt macOS canvas; both are glass.

    python3 Tools/Dev/make_app_icon.py App/Resources/AppIcon.icon

Preview with Icon Composer's ictool, for example:
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \\
        App/Resources/AppIcon.icon --export-image --output-file icon.png --platform macOS \\
        --rendition Default --width 512 --height 512 --scale 1
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FONT = os.path.join(ROOT, "App/Resources/Fonts/DepartureMono-Regular.otf")

# Theme's dark palette, lifted slightly where the icon needs contrast at small sizes.
CREAM, RAISED, CARD, BORDER, BADGE = "#F3F0EC", "#433F3C", "#272624", "#4C4744", "#7A7168"
BACKGROUND = ["extended-srgb:0.17255,0.16863,0.16078,1.00000",   # 2C2B29
              "extended-srgb:0.10196,0.09804,0.09412,1.00000"]   # 1A1918

CARD_W, CARD_H, CARDS_Y, GAP, RADIUS = 320, 452, 404, 32, 44
PROMPT_W, PROMPT_H, PROMPT_Y = 400, 168, 172


def glyph(text, size, cx, cy):
    return subprocess.run(
        ["swift", os.path.join(HERE, "glyph_paths.swift"), FONT, text, str(size), str(cx), str(cy)],
        capture_output=True, text=True, check=True).stdout.strip()


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>'


def bars(x0, y0, widths, step=52, height=26, opacity=0.55):
    return "".join(f'<rect x="{x0}" y="{y0 + i * step}" width="{w}" height="{height}" fill="{CREAM}" '
                   f'fill-opacity="{opacity}"/>' for i, w in enumerate(widths))


def card(x, letter, widths):
    header = CARDS_Y + 54
    return (f'<rect x="{x + 4}" y="{CARDS_Y + 4}" width="{CARD_W - 8}" height="{CARD_H - 8}" rx="{RADIUS - 4}" '
            f'fill="{CARD}" stroke="{BORDER}" stroke-width="8"/>'
            f'<circle cx="{x + 62}" cy="{header}" r="27" fill="none" stroke="{BADGE}" stroke-width="7"/>'
            f'<path fill="{CREAM}" d="{glyph(letter, 44, x + 62, header)}"/>'
            f'<rect x="{x + 110}" y="{header - 12}" width="{CARD_W - 172}" height="24" fill="{CREAM}" fill-opacity="0.88"/>'
            f'<rect x="{x + 4}" y="{CARDS_Y + 104}" width="{CARD_W - 8}" height="8" fill="{BORDER}"/>'
            + bars(x + 42, CARDS_Y + 150, widths))


def main(out):
    left, right = 512 - GAP // 2 - CARD_W, 512 + GAP // 2
    prompt_x = right + CARD_W - PROMPT_W
    prompt = (f'<rect x="{prompt_x}" y="{PROMPT_Y}" width="{PROMPT_W}" height="{PROMPT_H}" rx="{RADIUS}" fill="{RAISED}"/>'
              + bars(prompt_x + 48, PROMPT_Y + 46, [PROMPT_W - 112, PROMPT_W - 200], step=50, opacity=0.92))
    cards = card(left, "A", [236, 182, 212, 128, 196]) + card(right, "B", [212, 236, 150, 196, 104])
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(os.path.join(out, "Assets"))
    layers = {"prompt": prompt, "cards": cards}
    for name, body in layers.items():
        with open(os.path.join(out, "Assets", f"{name}.svg"), "w") as f:
            f.write(svg(body))
    group = lambda name: {
        "layers": [{"glass": True, "image-name": f"{name}.svg", "name": name,
                    "position": {"scale": 1, "translation-in-points": [0, 0]}}],
        "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5}}
    with open(os.path.join(out, "icon.json"), "w") as f:
        json.dump({"fill": {"linear-gradient": BACKGROUND,
                            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}},
                   "groups": [group(name) for name in layers],
                   "supported-platforms": {"squares": ["macOS"]}}, f, indent=2)


if __name__ == "__main__":
    main(sys.argv[1])
