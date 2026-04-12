"""
ダミー図面PNGを生成するプレースホルダスクリプト。
C-3方針: 動作確認用の簡素な図面。後で C-2（Excalidraw等で描いた実図面）に差し替える。
"""

from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

OUTPUT = Path(__file__).parent / "blade_pitch_control_diagram.png"

WIDTH, HEIGHT = 1200, 800
BG = (248, 249, 250)
BORDER = (11, 79, 138)
TEXT = (33, 37, 41)
ACCENT = (11, 79, 138)
MUTED = (134, 142, 150)
WARN_BG = (255, 233, 221)
WARN_BORDER = (245, 159, 0)


def find_japanese_font(size: int) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for path in candidates:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def main() -> None:
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    d = ImageDraw.Draw(img)

    title_font = find_japanese_font(32)
    label_font = find_japanese_font(20)
    small_font = find_japanese_font(16)
    tiny_font = find_japanese_font(13)

    d.rectangle([(20, 20), (WIDTH - 20, HEIGHT - 20)], outline=BORDER, width=3)

    d.text((50, 45), "Fig. 2  ブレードピッチ制御機構 配置図", font=title_font, fill=ACCENT)
    d.text((50, 90), "A-1000 Series / Blade Pitch Control Actuator Layout", font=small_font, fill=MUTED)
    d.text((50, 115), "Document: BPS-DWG-A1000-PITCH-v2.1", font=tiny_font, fill=MUTED)

    d.line([(50, 145), (WIDTH - 50, 145)], fill=BORDER, width=2)

    hub_cx, hub_cy = 600, 430
    hub_r = 90
    d.ellipse(
        [(hub_cx - hub_r, hub_cy - hub_r), (hub_cx + hub_r, hub_cy + hub_r)],
        outline=ACCENT,
        width=4,
        fill=(255, 255, 255),
    )
    d.text((hub_cx - 25, hub_cy - 12), "HUB", font=label_font, fill=ACCENT)

    blade_positions = [
        (hub_cx, hub_cy - 250, "Blade #1"),
        (hub_cx + 220, hub_cy + 140, "Blade #2"),
        (hub_cx - 220, hub_cy + 140, "Blade #3"),
    ]

    for bx, by, name in blade_positions:
        d.line([(hub_cx, hub_cy), (bx, by)], fill=ACCENT, width=8)
        d.ellipse([(bx - 18, by - 18), (bx + 18, by + 18)], outline=ACCENT, width=3, fill=(255, 255, 255))
        d.text((bx + 25, by - 12), name, font=small_font, fill=TEXT)

    actuator_positions = [
        (hub_cx, hub_cy - 100, "Pitch Actuator #1"),
        (hub_cx + 87, hub_cy + 55, "Pitch Actuator #2"),
        (hub_cx - 87, hub_cy + 55, "Pitch Actuator #3"),
    ]
    for ax, ay, name in actuator_positions:
        d.rectangle([(ax - 12, ay - 12), (ax + 12, ay + 12)], outline=(220, 53, 69), width=2, fill=(255, 220, 220))

    legend_x, legend_y = 60, HEIGHT - 230
    d.rectangle([(legend_x - 10, legend_y - 20), (legend_x + 380, legend_y + 180)], outline=MUTED, width=1, fill=(255, 255, 255))
    d.text((legend_x, legend_y - 10), "凡例 / Legend", font=label_font, fill=ACCENT)

    d.line([(legend_x + 10, legend_y + 30), (legend_x + 50, legend_y + 30)], fill=ACCENT, width=6)
    d.text((legend_x + 60, legend_y + 20), "ブレード構造体", font=small_font, fill=TEXT)

    d.rectangle([(legend_x + 15, legend_y + 55), (legend_x + 45, legend_y + 75)], outline=(220, 53, 69), width=2, fill=(255, 220, 220))
    d.text((legend_x + 60, legend_y + 55), "電動ピッチアクチュエータ (3基)", font=small_font, fill=TEXT)

    d.ellipse([(legend_x + 15, legend_y + 90), (legend_x + 45, legend_y + 120)], outline=ACCENT, width=3, fill=(255, 255, 255))
    d.text((legend_x + 60, legend_y + 95), "ピッチ軸受 (Blade root)", font=small_font, fill=TEXT)

    d.text((legend_x, legend_y + 140), "※ 各ブレードは独立制御。応答速度: 最大 8°/秒", font=tiny_font, fill=MUTED)

    note_x, note_y = WIDTH - 450, HEIGHT - 230
    d.rectangle([(note_x - 10, note_y - 20), (note_x + 410, note_y + 180)], outline=WARN_BORDER, width=2, fill=WARN_BG)
    d.text((note_x, note_y - 10), "⚠ 設計メモ (P.3 §3.4 参照)", font=label_font, fill=WARN_BORDER)

    memo_lines = [
        "現行制御アルゴリズム v3.2 は",
        "風速 5.0 m/s 以上の運転域を",
        "発電効率最適化の対象として設計。",
        "",
        "低風速域 (3.5〜5.0 m/s) の起動モード",
        "では発電効率は最適化対象外。",
    ]
    for i, line in enumerate(memo_lines):
        d.text((note_x, note_y + 25 + i * 22), line, font=small_font, fill=TEXT)

    footer = "BPS Corporation — 製品設計部 / 2025年3月 — Confidential"
    d.text((50, HEIGHT - 40), footer, font=tiny_font, fill=MUTED)
    d.text((WIDTH - 250, HEIGHT - 40), "⚠ PLACEHOLDER IMAGE (C-3)", font=tiny_font, fill=(220, 53, 69))

    img.save(OUTPUT, "PNG", optimize=True)
    print(f"Generated: {OUTPUT}  ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
