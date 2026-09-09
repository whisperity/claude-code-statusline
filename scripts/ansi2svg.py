#!/usr/bin/env python3
"""ansi2svg.py — turn real statusline.sh output into a README preview SVG.

Usage:
    ./statusline.sh < mock.json | python3 scripts/ansi2svg.py > docs/images/normal.svg

Reads ANSI-colored text (24-bit truecolor `\\033[38;2;R;G;Bm` sequences and
the small set of 8-color codes the script also uses) from stdin and renders
it as a dark terminal-window SVG matching docs/images/*.svg's style, so the
preview images can be regenerated from the script's actual behavior instead
of hand-edited whenever the output changes.
"""
import sys, re, html

COLOR_MAP = {
    30: "#000000", 31: "#E74C3C", 32: "#2ECC71", 33: "#F1C40F",
    34: "#3498DB", 35: "#D633C4", 36: "#5BC0DE", 37: "#cccccc",
    90: "#888888", 39: "#cccccc", 0: "#cccccc",
}


def parse_line(line):
    """Split one line of ANSI-colored text into (color_hex, text, dim) runs."""
    segs = []
    cur = "#cccccc"
    dim = False
    for chunk in re.split(r'(\x1b\[[0-9;]*m)', line):
        if not chunk:
            continue
        m = re.match(r'\x1b\[([0-9;]*)m', chunk)
        if m:
            codes = m.group(1).split(';')
            j = 0
            while j < len(codes):
                c = codes[j]
                if c == '' or c == '0':
                    cur = "#cccccc"; dim = False
                elif c == '2':
                    dim = True
                elif c == '38' and j + 1 < len(codes) and codes[j + 1] == '2':
                    r, g, b = codes[j + 2], codes[j + 3], codes[j + 4]
                    cur = "#%02x%02x%02x" % (int(r), int(g), int(b))
                    j += 4
                elif c.isdigit():
                    cur = COLOR_MAP.get(int(c), cur)
                j += 1
        else:
            segs.append((cur, chunk, dim))
    return segs


def esc(s):
    return html.escape(s, quote=False)


def main():
    raw = sys.stdin.read()
    lines = [l for l in raw.split('\n') if l.strip('\r') != '']

    char_w = 7.85
    font_size = 13
    y0 = 30
    max_len = 0
    svg_lines = []

    for idx, line in enumerate(lines):
        segs = parse_line(line)
        max_len = max(max_len, sum(len(t) for _, t, _ in segs))
        y = y0 + idx * 26
        tspans = []
        for i, (color, text, dim) in enumerate(segs):
            attrs = f'fill="{color}"'
            if dim:
                attrs += ' fill-opacity="0.6"'
            pos = f'x="16" y="{y}" ' if i == 0 else ''
            tspans.append(f'<tspan {pos}{attrs}>{esc(text)}</tspan>')
        svg_lines.append(''.join(tspans))

    width = max(int(max_len * char_w) + 32, 300)
    height = y0 - 20 + len(lines) * 26 + 18

    print(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">')
    print(f'  <rect width="{width}" height="{height}" rx="8" fill="#1a1b26"/>')
    print(f'  <text font-family="\'JetBrains Mono\',\'Fira Code\',\'SF Mono\',Menlo,Consolas,monospace" font-size="{font_size}">')
    for sl in svg_lines:
        print(f'    {sl}')
    print('  </text>')
    print('</svg>')


if __name__ == "__main__":
    main()
