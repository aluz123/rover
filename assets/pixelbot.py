#!/usr/bin/env python3
"""Rover's pixel mascot (original design by Alex Towfigh's Rover project, MIT). Writes icon.svg + menubar.svg."""
import sys
SPRITE = [
 "..............KKKK..............",
 ".............KTWTTK.............",
 ".............KTTTTK.............",
 "..............KKKK..............",
 "...............KK...............",
 "...............KK...............",
 "......KKKKKKKKKKKKKKKKKKKK......",
 ".....KHHHHHHHHHHHHHHHHHHHHK.....",
 ".....KOKKKKKKKKKKKKKKKKKKOK.....",
 ".....KOKSSTTTSSSSSSSSSSSKDK.....",
 ".....KOKSTSSSTSSSSSSSSSSKDK.....",
 ".....KOKSTSWSTSSSTTTTSSSKDK.....",
 ".....KOKSTSSSTSSSSSSSSSSKDK.....",
 ".....KOKSSTTTSTSSSSSSSSSKDK.....",
 ".....KOKSSSSSSSTSSSSSTTSKDK.....",
 ".....KOKKKKKKKKKKKKKKKKKKDK.....",
 ".....KOOOOOOOOOOOOOOOOODDDK.....",
 "......KKKKKKKKKKKKKKKKKKKK......",
 "..............KDDK..............",
 ".........KKKKKKKKKKKKKK.........",
 "......KKKKHHHHHHHHHHHHKKKK......",
 "......KOOKOKKKKKKKKKKOKOOK......",
 "......KOOKOKTTTSSSSSKOKOOK......",
 "......KKKKOKTTTTTTTTKOKKKK......",
 ".........KOKTTTTTTTTKDK.........",
 ".........KOKKKKKKKKKKDK.........",
 ".........KKKKKKKKKKKKKK.........",
 ".....KKKKKKKKKKKKKKKKKKKKKK.....",
 "....KLGLGLGLGLGLGLGLGLGLGLGK....",
 "....KGAAGGAAGGAAGGAAGGAAGGGK....",
 "....KLGLGLGLGLGLGLGLGLGLGLGK....",
 ".....KKKKKKKKKKKKKKKKKKKKKK.....",
]
for i, r in enumerate(SPRITE):
    assert len(r) == 32, (i, len(r), r)
PAL = {"K": "#1A1430", "O": "#FF8A3D", "D": "#C85A26", "H": "#FFC291", "S": "#0B1424", "T": "#3CF2D0",
       "W": "#FFFFFF", "G": "#3A3452", "L": "#5C5578", "A": "#9A93BC"}

def rects(px, ox, oy, pick):
    out = []
    for y, row in enumerate(SPRITE):
        x = 0
        while x < 32:
            c = row[x]
            col = pick(c)
            if col is None: x += 1; continue
            run = 1
            while x + run < 32 and pick(row[x + run]) == col: run += 1
            out.append(f'<rect x="{ox + x*px}" y="{oy + y*px}" width="{run*px}" height="{px}" fill="{col}"/>')
            x += run
    return "\n".join(out)

px = 19
ox, oy = 512 - 16*px, 520 - 16*px
stars = "".join(f'<rect x="{x}" y="{y}" width="12" height="12" fill="#8FA2FF" opacity="{o}"/>' for x, y, o in
                [(196,224,.5),(820,260,.35),(260,760,.3),(770,700,.45),(704,176,.3),(170,520,.25),(842,520,.3)])
icon = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" shape-rendering="crispEdges">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2A1F5C"/><stop offset="1" stop-color="#0B0820"/></linearGradient>
  <radialGradient id="glow" cx="0.5" cy="0.47" r="0.45"><stop offset="0" stop-color="#3CF2D0" stop-opacity="0.22"/><stop offset="1" stop-color="#3CF2D0" stop-opacity="0"/></radialGradient>
  <clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
</defs>
<g clip-path="url(#sq)">
  <rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>
  <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
  {stars}
  <rect x="{ox + 3*px}" y="{oy + 32*px + 6}" width="{26*px}" height="{px}" fill="#000" opacity="0.35"/>
</g>
{rects(px, ox, oy, lambda c: PAL.get(c))}
</svg>'''
open("icon.svg", "w").write(icon)

# menu bar template: solid silhouette, screen dark parts cut out, lens + wink kept
mb = f'''<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 32 32" shape-rendering="crispEdges">
{rects(1, 0, 0, lambda c: None if c in ".S" else "#000")}
</svg>'''
open("menubar.svg", "w").write(mb)
print("ok")
