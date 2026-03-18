from fpdf import FPDF
import os

pdf = FPDF()
pdf.set_auto_page_break(auto=True, margin=15)

# Find Japanese font
font_path = None
for d in [os.path.expanduser("~/Library/Fonts"), "/Library/Fonts", "/System/Library/Fonts", "/System/Library/Fonts/Supplemental"]:
    if not os.path.isdir(d):
        continue
    for f in os.listdir(d):
        if "NotoSans" in f and "JP" in f and f.endswith(".ttf"):
            font_path = os.path.join(d, f)
            break
    if font_path:
        break

if not font_path:
    # Try Hiragino
    h = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
    if os.path.exists(h):
        font_path = h

if not font_path:
    # List what's available
    for d in ["/System/Library/Fonts", "/Library/Fonts", os.path.expanduser("~/Library/Fonts")]:
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                print(f"  {d}/{f}")
    raise RuntimeError("No Japanese font found")

print(f"Using font: {font_path}")
pdf.add_font("JP", "", font_path)

pdf.add_page()
pdf.set_font("JP", size=14)
pdf.cell(0, 10, "テクノフューチャー株式会社 社内IT FAQ", new_x="LMARGIN", new_y="NEXT", align="C")
pdf.set_font("JP", size=8)
pdf.cell(0, 6, "最終更新日: 2026年3月14日  対象: 全社員", new_x="LMARGIN", new_y="NEXT", align="C")
pdf.ln(5)

with open("rag-test-faq.txt", "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        # Skip decorative lines and header (already added above)
        if line.startswith("=====") or line.startswith("-----"):
            continue
        if "テクノフューチャー" in line and "FAQ" in line:
            continue
        if line.startswith("最終更新日") or line.startswith("対象:"):
            continue

        if line.startswith("■"):
            pdf.ln(4)
            pdf.set_font("JP", size=11)
            pdf.multi_cell(0, 7, line)
            pdf.ln(2)
        elif line.startswith("Q"):
            pdf.ln(2)
            pdf.set_font("JP", size=9)
            pdf.multi_cell(0, 5.5, line)
        elif line.startswith("A"):
            pdf.set_font("JP", size=8)
            pdf.multi_cell(0, 5, line)
        elif line.strip() == "":
            pdf.ln(1)
        else:
            pdf.set_font("JP", size=8)
            pdf.multi_cell(0, 5, line)

pdf.output("rag-test-faq.pdf")
print(f"PDF created: {os.path.abspath('rag-test-faq.pdf')}")
print(f"Size: {os.path.getsize('rag-test-faq.pdf') / 1024:.1f} KB")
