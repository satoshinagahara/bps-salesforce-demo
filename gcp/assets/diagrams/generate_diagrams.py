"""
デモ用図面PNG生成スクリプト。
A-1000 ブレードピッチ制御機構 + E-2000 BMS アーキテクチャの2枚を生成。
"""

from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

OUTPUT_DIR = Path(__file__).parent

WIDTH, HEIGHT = 1200, 800
BG = (255, 255, 255)
BORDER = (11, 79, 138)
TEXT = (33, 37, 41)
ACCENT = (11, 79, 138)
MUTED = (134, 142, 150)
RED = (220, 53, 69)
GREEN = (46, 132, 74)
ORANGE = (245, 159, 0)
LIGHT_BLUE = (219, 234, 254)
LIGHT_RED = (255, 230, 230)
LIGHT_GREEN = (212, 237, 218)
LIGHT_ORANGE = (255, 243, 205)


def find_font(size: int) -> ImageFont.FreeTypeFont:
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


def draw_rounded_rect(d, xy, radius, fill=None, outline=None, width=1):
    x0, y0, x1, y1 = xy
    d.rounded_rectangle(xy, radius=radius, fill=fill, outline=outline, width=width)


def generate_a1000():
    """A-1000 ブレードピッチ制御機構 配置図"""
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    d = ImageDraw.Draw(img)

    tf = find_font(28)
    lf = find_font(18)
    sf = find_font(14)
    xsf = find_font(12)

    # Border & title
    d.rectangle([(15, 15), (WIDTH-15, HEIGHT-15)], outline=BORDER, width=2)
    d.rectangle([(15, 15), (WIDTH-15, 55)], fill=ACCENT)
    d.text((30, 20), "Fig. 2  A-1000 ブレードピッチ制御機構 配置図", font=lf, fill=(255,255,255))
    d.text((WIDTH-350, 22), "BPS-DWG-A1000-PITCH-v2.1", font=sf, fill=(200,210,230))

    # Hub
    hub_cx, hub_cy = 450, 380
    hub_r = 70
    d.ellipse([(hub_cx-hub_r, hub_cy-hub_r), (hub_cx+hub_r, hub_cy+hub_r)], outline=ACCENT, width=4, fill=LIGHT_BLUE)
    d.text((hub_cx-30, hub_cy-25), "HUB", font=lf, fill=ACCENT)
    d.text((hub_cx-40, hub_cy+2), "Main Shaft", font=xsf, fill=MUTED)

    # Blades
    blade_data = [
        (hub_cx, hub_cy-230, "Blade #1", "73m GFRP"),
        (hub_cx+200, hub_cy+130, "Blade #2", "73m GFRP"),
        (hub_cx-200, hub_cy+130, "Blade #3", "73m GFRP"),
    ]
    for bx, by, name, spec in blade_data:
        d.line([(hub_cx, hub_cy), (bx, by)], fill=ACCENT, width=10)
        d.ellipse([(bx-15, by-15), (bx+15, by+15)], outline=ACCENT, width=3, fill=(255,255,255))
        d.text((bx+22, by-18), name, font=sf, fill=TEXT)
        d.text((bx+22, by+0), spec, font=xsf, fill=MUTED)

    # Actuators with detail
    act_data = [
        (hub_cx+5, hub_cy-105, "#1"),
        (hub_cx+82, hub_cy+48, "#2"),
        (hub_cx-72, hub_cy+48, "#3"),
    ]
    for ax, ay, num in act_data:
        draw_rounded_rect(d, (ax-16, ay-12, ax+16, ay+12), 3, fill=LIGHT_RED, outline=RED, width=2)
        d.text((ax-6, ay-8), num, font=xsf, fill=RED)

    # Nacelle outline
    d.rounded_rectangle([(hub_cx+hub_r+10, hub_cy-60), (hub_cx+hub_r+150, hub_cy+60)], radius=8, outline=MUTED, width=2)
    d.text((hub_cx+hub_r+20, hub_cy-45), "Nacelle", font=sf, fill=MUTED)
    d.text((hub_cx+hub_r+20, hub_cy-25), "PMSG 5MW", font=xsf, fill=MUTED)
    d.text((hub_cx+hub_r+20, hub_cy-5), "Gearless", font=xsf, fill=MUTED)
    d.text((hub_cx+hub_r+20, hub_cy+15), "Yaw Control", font=xsf, fill=MUTED)

    # Control system block
    ctrl_x, ctrl_y = 780, 100
    draw_rounded_rect(d, (ctrl_x, ctrl_y, ctrl_x+350, ctrl_y+210), 8, fill=(248,249,250), outline=ACCENT, width=2)
    d.text((ctrl_x+10, ctrl_y+8), "Pitch Control System", font=lf, fill=ACCENT)
    d.line([(ctrl_x+10, ctrl_y+35), (ctrl_x+340, ctrl_y+35)], fill=ACCENT, width=1)

    modes = [
        ("STOP", "~3.5 m/s", MUTED),
        ("START", "3.5~5.0 m/s", ORANGE),
        ("PARTIAL", "5.0~12.0 m/s", GREEN),
        ("RATED", "12.0~25.0 m/s", ACCENT),
    ]
    for i, (mode, wind, color) in enumerate(modes):
        y = ctrl_y + 50 + i*38
        d.rounded_rectangle([(ctrl_x+15, y), (ctrl_x+110, y+28)], radius=4, fill=color, outline=color)
        d.text((ctrl_x+20, y+4), mode, font=sf, fill=(255,255,255))
        d.text((ctrl_x+120, y+6), wind, font=sf, fill=TEXT)

    # Warning box
    warn_x, warn_y = 780, 340
    draw_rounded_rect(d, (warn_x, warn_y, warn_x+350, warn_y+160), 6, fill=LIGHT_ORANGE, outline=ORANGE, width=2)
    d.text((warn_x+10, warn_y+8), "Design Note (P.3 §3.4)", font=sf, fill=ORANGE)
    d.line([(warn_x+10, warn_y+28), (warn_x+340, warn_y+28)], fill=ORANGE, width=1)
    note_lines = [
        "START mode (3.5~5.0 m/s):",
        "  Efficiency NOT optimized",
        "  Startup torque only",
        "",
        "TSR tracking: suboptimal",
        "Inertia loss: significant",
        "→ FW v4.0 candidate",
    ]
    for i, line in enumerate(note_lines):
        d.text((warn_x+15, warn_y+35+i*16), line, font=xsf, fill=TEXT)

    # Specs box
    spec_x, spec_y = 780, 530
    draw_rounded_rect(d, (spec_x, spec_y, spec_x+350, spec_y+100), 6, fill=(248,249,250), outline=MUTED, width=1)
    d.text((spec_x+10, spec_y+8), "Actuator Specs", font=sf, fill=ACCENT)
    specs = [
        "Type: Electric pitch motor (hydraulic-free)",
        "Response: max 8°/sec",
        "Position: Blade root (hub-internal)",
        "Control: Independent per blade",
    ]
    for i, s in enumerate(specs):
        d.text((spec_x+15, spec_y+30+i*16), s, font=xsf, fill=TEXT)

    # Legend
    leg_x, leg_y = 30, HEIGHT-100
    d.rectangle([(leg_x, leg_y), (leg_x+350, leg_y+75)], fill=(248,249,250), outline=MUTED, width=1)
    d.text((leg_x+10, leg_y+5), "Legend", font=sf, fill=ACCENT)
    d.line([(leg_x+20, leg_y+30), (leg_x+60, leg_y+30)], fill=ACCENT, width=8)
    d.text((leg_x+70, leg_y+22), "Blade structure (GFRP)", font=xsf, fill=TEXT)
    d.rectangle([(leg_x+20, leg_y+45), (leg_x+50, leg_y+62)], fill=LIGHT_RED, outline=RED, width=2)
    d.text((leg_x+70, leg_y+46), "Pitch actuator (x3, independent)", font=xsf, fill=TEXT)

    # Footer
    d.text((30, HEIGHT-22), "BPS Corporation / Product Engineering / 2025", font=xsf, fill=MUTED)

    img.save(OUTPUT_DIR / "blade_pitch_control_diagram.png", "PNG", optimize=True)
    print(f"A-1000: {OUTPUT_DIR / 'blade_pitch_control_diagram.png'}")


def generate_e2000():
    """E-2000 BMS アーキテクチャ図"""
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    d = ImageDraw.Draw(img)

    tf = find_font(28)
    lf = find_font(18)
    sf = find_font(14)
    xsf = find_font(12)

    # Border & title
    d.rectangle([(15, 15), (WIDTH-15, HEIGHT-15)], outline=ACCENT, width=2)
    d.rectangle([(15, 15), (WIDTH-15, 55)], fill=ACCENT)
    d.text((30, 20), "Fig. 1  E-2000 EnerCharge Pro BMS アーキテクチャ", font=lf, fill=(255,255,255))
    d.text((WIDTH-330, 22), "BPS-DWG-E2000-BMS-v2.4", font=sf, fill=(200,210,230))

    # Container outline
    d.rounded_rectangle([(40, 70), (750, 650)], radius=10, outline=MUTED, width=2)
    d.text((50, 75), "20ft Container (IP55)", font=sf, fill=MUTED)

    # Battery modules (4x4 grid)
    mod_w, mod_h = 130, 55
    for row in range(4):
        for col in range(4):
            mx = 70 + col * (mod_w + 15)
            my = 120 + row * (mod_h + 20)
            mod_num = row * 4 + col + 1
            fill = LIGHT_RED if mod_num in [13,14,15,16] else LIGHT_BLUE
            outline = ORANGE if mod_num in [13,14,15,16] else ACCENT
            draw_rounded_rect(d, (mx, my, mx+mod_w, my+mod_h), 5, fill=fill, outline=outline, width=2)
            d.text((mx+8, my+5), f"Module {mod_num:02d}", font=sf, fill=TEXT)
            d.text((mx+8, my+25), "LFP 14S8P 51.2V", font=xsf, fill=MUTED)
            # Temperature sensor dots
            d.ellipse([(mx+mod_w-20, my+8), (mx+mod_w-12, my+16)], fill=GREEN)
            d.ellipse([(mx+mod_w-20, my+mod_h-16), (mx+mod_w-12, my+mod_h-8)], fill=GREEN)

    # Cooling fans
    fan_y = 440
    for i in range(4):
        fx = 85 + i * 160
        d.ellipse([(fx, fan_y), (fx+40, fan_y+40)], outline=ACCENT, width=2, fill=(230,240,255))
        d.text((fx+8, fan_y+10), "FAN", font=xsf, fill=ACCENT)
        d.text((fx+45, fan_y+12), f"Fan #{i+1}", font=xsf, fill=MUTED)

    # BMS hierarchy (right side)
    bms_x = 790

    # System BMS
    draw_rounded_rect(d, (bms_x, 80, bms_x+360, 170), 8, fill=LIGHT_BLUE, outline=ACCENT, width=3)
    d.text((bms_x+10, 88), "System BMS (SBMS)", font=lf, fill=ACCENT)
    d.text((bms_x+10, 115), "Overall control / PCS link / SCADA", font=xsf, fill=TEXT)
    d.text((bms_x+10, 135), "SOC/SOH aggregation / Alarm mgmt", font=xsf, fill=TEXT)

    # Module BMS
    for i in range(4):
        by = 200 + i * 70
        draw_rounded_rect(d, (bms_x+30, by, bms_x+330, by+55), 6, fill=(248,249,250), outline=ACCENT, width=2)
        d.text((bms_x+40, by+5), f"BMU Group {i+1} (Module {i*4+1:02d}-{i*4+4:02d})", font=sf, fill=TEXT)
        d.text((bms_x+40, by+28), "SOC/SOH calc / Cell balancing", font=xsf, fill=MUTED)
        # Connection line
        d.line([(bms_x+180, 170), (bms_x+180, by)], fill=ACCENT, width=1)

    # Warning box
    warn_x, warn_y = bms_x, 500
    draw_rounded_rect(d, (warn_x, warn_y, warn_x+360, warn_y+150), 6, fill=LIGHT_ORANGE, outline=ORANGE, width=2)
    d.text((warn_x+10, warn_y+8), "Design Note (P.3 §3.4)", font=sf, fill=ORANGE)
    d.line([(warn_x+10, warn_y+28), (warn_x+350, warn_y+28)], fill=ORANGE, width=1)
    note_lines = [
        "High-temp (35~45C) operation:",
        "  Charge/discharge NOT optimized",
        "  Output limited to 75% only",
        "",
        "Air cooling limit: 40C+ ambient",
        "SOC accuracy degrades at high temp",
        "Cycle life warranty: 25C only",
        "→ FW v3.0 candidate",
    ]
    for i, line in enumerate(note_lines):
        d.text((warn_x+15, warn_y+35+i*14), line, font=xsf, fill=TEXT)

    # PCS block
    pcs_x, pcs_y = 70, 510
    draw_rounded_rect(d, (pcs_x, pcs_y, pcs_x+280, pcs_y+60), 8, fill=(248,249,250), outline=ACCENT, width=2)
    d.text((pcs_x+10, pcs_y+8), "PCS (250kW Bi-directional)", font=sf, fill=ACCENT)
    d.text((pcs_x+10, pcs_y+30), "SiC MOSFET / DC700-900V ↔ AC400V", font=xsf, fill=MUTED)

    # SCADA connection
    d.text((pcs_x, pcs_y+70), "→ Grid / Load", font=sf, fill=MUTED)
    d.text((bms_x+10, 65), "↑ SCADA (Modbus TCP)", font=xsf, fill=MUTED)

    # Legend
    leg_x, leg_y = 400, 510
    d.rectangle([(leg_x, leg_y), (leg_x+320, leg_y+120)], fill=(248,249,250), outline=MUTED, width=1)
    d.text((leg_x+10, leg_y+5), "Legend", font=sf, fill=ACCENT)
    d.rectangle([(leg_x+10, leg_y+25), (leg_x+35, leg_y+42)], fill=LIGHT_BLUE, outline=ACCENT, width=2)
    d.text((leg_x+45, leg_y+26), "Normal module (< 35C)", font=xsf, fill=TEXT)
    d.rectangle([(leg_x+10, leg_y+50), (leg_x+35, leg_y+67)], fill=LIGHT_RED, outline=ORANGE, width=2)
    d.text((leg_x+45, leg_y+51), "High-temp risk module (35~45C)", font=xsf, fill=TEXT)
    d.ellipse([(leg_x+15, leg_y+78), (leg_x+25, leg_y+88)], fill=GREEN)
    d.text((leg_x+45, leg_y+76), "Temperature sensor (x32 total)", font=xsf, fill=TEXT)
    d.text((leg_x+10, leg_y+98), "Module 13-16: higher thermal load (bottom row)", font=xsf, fill=MUTED)

    # Footer
    d.text((30, HEIGHT-22), "BPS Corporation / Product Engineering / 2025", font=xsf, fill=MUTED)

    img.save(OUTPUT_DIR / "e2000_bms_architecture.png", "PNG", optimize=True)
    print(f"E-2000: {OUTPUT_DIR / 'e2000_bms_architecture.png'}")


if __name__ == "__main__":
    generate_a1000()
    generate_e2000()
