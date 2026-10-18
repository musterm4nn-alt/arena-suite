"""Generates the app icon, an Icon Composer document (App/Resources/AppIcon.icon).

The mark is an arena gate: a cream arch inside two faint amphitheatre tiers, standing on the arena
floor. Its opening holds two lanes, coral and blue, for the two anonymous models of a battle; the
lines on them are the archived transcripts. Layers are SVG on the 1024 pt macOS canvas; the gate and
lanes are glass.

    python3 Tools/Dev/make_app_icon.py App/Resources/AppIcon.icon [key=json ...]

Preview with Icon Composer's ictool, for example:
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
        App/Resources/AppIcon.icon --export-image --output-file icon.png --platform macOS \
        --rendition Default --width 512 --height 512 --scale 1
"""
import sys, math, json, os
D = sys.argv[1]
P = dict(cx=512, cy=452, R=270, r=166, foot=840, tiers=[(330, 0.24), (378, 0.12)], tier_w=22,
         pad=24, gap=24, line_y=546, line_step=54, floor=["#3A3430", "#211E1B"])
for kv in sys.argv[2:]:
    k, v = kv.split("="); P[k] = json.loads(v)
cx, cy, R, r, foot = P["cx"], P["cy"], P["R"], P["r"], P["foot"]
os.makedirs(f"{D}/Assets", exist_ok=True)
def arch(R_out, R_in, bottom):
    return (f"M{cx-R_out},{bottom} L{cx-R_out},{cy} A{R_out},{R_out} 0 0 1 {cx+R_out},{cy} L{cx+R_out},{bottom} "
            f"L{cx+R_in},{bottom} L{cx+R_in},{cy} A{R_in},{R_in} 0 0 0 {cx-R_in},{cy} L{cx-R_in},{bottom} Z")
svg = lambda body, defs="": f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>{defs}</defs>{body}</svg>'
grad = lambda i, a, b: f'<linearGradient id="{i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'
open(f"{D}/Assets/gate.svg", "w").write(svg(f'<path fill="url(#g)" d="{arch(R, r, foot)}"/>', grad("g", "#FCF8F2", "#DDD2C4")))
open(f"{D}/Assets/tiers.svg", "w").write(svg("".join(
    f'<path fill="#F3EDE4" fill-opacity="{op}" d="{arch(ro, ro - P["tier_w"], foot)}"/>' for ro, op in P["tiers"])))
ri = r - P["pad"]; g2 = P["gap"] / 2
xl0, xl1, xr0, xr1 = cx - ri, cx - g2, cx + g2, cx + ri
top = lambda x: cy - math.sqrt(ri * ri - (x - cx) ** 2)
lines = ""
for x0, widths in [(xl0 + 30, [84, 58, 74]), (xr0 + 30, [84, 70, 50])]:
    for k, w in enumerate(widths):
        lines += f'<rect x="{x0}" y="{P["line_y"] + k * P["line_step"]}" width="{w}" height="22" rx="11"/>'
open(f"{D}/Assets/lanes.svg", "w").write(svg(
    f'<path fill="url(#a)" d="M{xl0},{foot} L{xl0},{cy} A{ri},{ri} 0 0 1 {xl1},{top(xl1):.1f} L{xl1},{foot} Z"/>'
    f'<path fill="url(#b)" d="M{xr0},{foot} L{xr0},{top(xr0):.1f} A{ri},{ri} 0 0 1 {xr1},{cy} L{xr1},{foot} Z"/>'
    f'<g fill="#FFFFFF" fill-opacity="0.46">{lines}</g>',
    grad("a", "#FF9C6C", "#E9452A") + grad("b", "#86ABFF", "#2F4FE2")))
if P.get("floor"):
    fy = P["foot"]
    open(f"{D}/Assets/floor.svg", "w").write(svg(
        f'<rect x="-10" y="{fy}" width="1044" height="{1034 - fy}" fill="url(#f)"/>'
        f'<rect x="-10" y="{fy}" width="1044" height="10" fill="#F3EDE4" fill-opacity="0.22"/>',
        grad("f", P["floor"][0], P["floor"][1])))
def group(name, glass, shadow, translucency=None):
    return {"layers": [{"glass": glass, "image-name": f"{name}.svg", "name": name,
                        "position": {"scale": 1, "translation-in-points": [0, 0]}}],
            "shadow": {"kind": shadow, "opacity": 0.5},
            "translucency": {"enabled": translucency is not None, "value": translucency or 0.5}}
json.dump({"fill": {"linear-gradient": ["extended-srgb:0.23137,0.20784,0.18824,1.00000", "extended-srgb:0.07059,0.06667,0.06275,1.00000"],
                    "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}},
           "groups": [group("gate", True, "neutral"), group("lanes", True, "layer-color"), group("tiers", False, "none")]
                     + ([group("floor", False, "none")] if P.get("floor") else []),
           "supported-platforms": {"squares": ["macOS"]}}, open(f"{D}/icon.json", "w"), indent=2)
