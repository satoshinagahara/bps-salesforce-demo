#!/usr/bin/env python3
"""Generate 5 sample supplier quote HTML files for IDP demo.

Each sample uses a DIFFERENT layout + different label conventions to demonstrate
that IDP should normalize varied document formats into the same JSON schema.

Baseline values match RFQ_Quote__c test record a2xIe000000Go5QIAS (QT-0032):
  Supplier: 東亜電子工業
  Unit Price: ¥4,800
  Lead Time: 45 days
  MOQ: 1,000
  Mfg Site: 東亜電子 本社工場
  Valid Until: 2026-07-31
  Response Date: 2026-04-20

Samples 1-3 use baseline values (should all yield 🟢 一致) to demonstrate
layout-agnostic extraction. Samples 4-5 introduce value discrepancies to
demonstrate dual-check judgment.
"""
from pathlib import Path

DIR = Path(__file__).resolve().parent


def fmt_jp_date(iso: str) -> str:
    y, m, d = iso.split("-")
    return f"{y}年{int(m)}月{int(d)}日"


def fmt_slash_date(iso: str) -> str:
    y, m, d = iso.split("-")
    return f"{y}/{int(m)}/{int(d)}"


# ============================================================
# 01: Traditional Japanese formal letterhead style
# ============================================================
def build_formal_letterhead(supplier, unit_price, lead_days, moq, mfg_site, valid_until, response_date, quote_no, **_):
    return f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8"><title>御見積書 {quote_no}</title>
<style>
@page {{ size: A4; margin: 18mm; }}
body {{ font-family: "Hiragino Mincho ProN", "YuMincho", serif; color: #1a1a1a; font-size: 11pt; }}
h1 {{ text-align: center; border-top: 3px double #000; border-bottom: 3px double #000; padding: 12px 0; letter-spacing: 0.8em; font-size: 22pt; margin: 8px 0 24px 0; font-weight: normal; }}
.header-row {{ display: flex; justify-content: space-between; margin-bottom: 16px; font-size: 10pt; }}
.issuer-box {{ background: #f8f8f6; border: 1px solid #888; padding: 10px 16px; margin: 18px 0; }}
.issuer-box .name {{ font-size: 13pt; font-weight: bold; margin-bottom: 4px; }}
.greeting {{ margin: 18px 0; }}
.items {{ width: 100%; border-collapse: collapse; margin: 18px 0; }}
.items th, .items td {{ border: 1.5px solid #333; padding: 12px 10px; text-align: left; font-size: 10.5pt; }}
.items th {{ background: #e5e5e0; text-align: center; font-weight: bold; }}
.items .total {{ background: #fff9e0; font-weight: bold; }}
.terms {{ margin-top: 24px; font-size: 10pt; }}
.terms h2 {{ font-size: 11pt; border-left: 4px solid #555; padding-left: 8px; margin: 16px 0 8px 0; }}
.terms-table {{ width: 100%; border-collapse: collapse; }}
.terms-table td {{ padding: 6px 12px; border: 1px solid #999; }}
.terms-table td.lbl {{ background: #f0f0ee; width: 32%; font-weight: 600; }}
.footer {{ text-align: right; margin-top: 30px; font-size: 9pt; color: #555; }}
</style></head><body>

<h1>御 見 積 書</h1>

<div class="header-row">
<div></div>
<div>発行日: {fmt_jp_date(response_date)}<br/>見積番号: {quote_no}</div>
</div>

<div class="issuer-box">
<div class="name">{supplier}</div>
<div>本社: 愛知県名古屋市中区栄1-2-3</div>
<div>営業部 田中太郎  TEL: 052-xxx-xxxx</div>
</div>

<p class="greeting">平素より格別のご高配を賜り厚く御礼申し上げます。<br/>
下記の通り、お見積書をご提出申し上げます。</p>

<table class="items">
<tr><th style="width:40%">品目</th><th style="width:20%">単価</th><th style="width:15%">数量</th><th style="width:25%">金額</th></tr>
<tr><td>電源モジュール<br/><span style="color:#666;font-size:9pt">型番: P-IDP-TEST-001</span></td>
<td style="text-align:right">¥{unit_price:,}</td>
<td style="text-align:right">{moq:,}</td>
<td class="total" style="text-align:right">¥{unit_price*moq:,}</td></tr>
</table>

<div class="terms">
<h2>取引条件</h2>
<table class="terms-table">
<tr><td class="lbl">最小発注数量 (MOQ)</td><td>{moq:,} 個</td></tr>
<tr><td class="lbl">納期</td><td>発注後 {lead_days} 日</td></tr>
<tr><td class="lbl">製造拠点</td><td>{mfg_site}</td></tr>
<tr><td class="lbl">見積有効期限</td><td>{fmt_jp_date(valid_until)}</td></tr>
<tr><td class="lbl">支払条件</td><td>月末締め翌月末払い(銀行振込)</td></tr>
</table>
</div>

<div class="footer">以上</div>
</body></html>
"""


# ============================================================
# 02: Compact fax-style with simple labels
# ============================================================
def build_simple_fax(supplier, unit_price, lead_days, moq, mfg_site, valid_until, response_date, quote_no, **_):
    return f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8"><title>見積FAX {quote_no}</title>
<style>
@page {{ size: A4; margin: 20mm; }}
body {{ font-family: "Hiragino Sans", "Helvetica", sans-serif; color: #000; font-size: 11pt; line-height: 1.9; }}
.fax-header {{ border: 3px solid #000; padding: 8px; text-align: center; font-size: 14pt; font-weight: bold; margin-bottom: 16px; letter-spacing: 0.5em; }}
.meta-line {{ border-bottom: 1px dashed #555; padding: 4px 0; margin-bottom: 20px; display: flex; justify-content: space-between; }}
.block-title {{ background: #e0e0e0; padding: 4px 8px; font-weight: bold; margin: 16px 0 8px 0; border-left: 4px solid #333; }}
.kv {{ padding: 3px 0; }}
.kv .k {{ display: inline-block; width: 16em; color: #333; }}
.kv .v {{ font-weight: bold; }}
.note {{ margin-top: 24px; padding: 8px; background: #fffbe5; border-left: 3px solid #b89500; font-size: 10pt; }}
</style></head><body>

<div class="fax-header">見 積 書 (FAX)</div>

<div class="meta-line">
<span>発行: {fmt_slash_date(response_date)}</span>
<span>No. {quote_no}</span>
<span>宛先: BPS購買部 御中</span>
</div>

<div class="block-title">■ 発行元</div>
<div class="kv"><span class="k">会社名:</span><span class="v">{supplier}</span></div>
<div class="kv"><span class="k">担当:</span><span class="v">営業部 田中</span></div>

<div class="block-title">■ 見積明細</div>
<div class="kv"><span class="k">品番:</span><span class="v">P-IDP-TEST-001 電源モジュール</span></div>
<div class="kv"><span class="k">数量:</span><span class="v">{moq:,}個</span></div>
<div class="kv"><span class="k">ユニット価格:</span><span class="v">¥{unit_price:,} (税抜)</span></div>
<div class="kv"><span class="k">デリバリー:</span><span class="v">{lead_days}日</span></div>
<div class="kv"><span class="k">最低ロット:</span><span class="v">{moq:,}個</span></div>
<div class="kv"><span class="k">工場:</span><span class="v">{mfg_site}</span></div>
<div class="kv"><span class="k">期限:</span><span class="v">{fmt_slash_date(valid_until)}</span></div>

<div class="note">※ 送信エラー時は 052-xxx-xxxx までご連絡ください</div>

</body></html>
"""


# ============================================================
# 03: Narrative business letter (prose, values in sentences)
# ============================================================
def build_narrative_letter(supplier, unit_price, lead_days, moq, mfg_site, valid_until, response_date, quote_no, **_):
    return f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8"><title>お見積のご案内 {quote_no}</title>
<style>
@page {{ size: A4; margin: 25mm; }}
body {{ font-family: "Hiragino Mincho ProN", "YuMincho", serif; color: #1a1a1a; font-size: 11.5pt; line-height: 1.9; }}
.letter-head {{ text-align: right; margin-bottom: 20px; font-size: 10pt; color: #444; }}
.to {{ margin-bottom: 30px; font-size: 12pt; }}
.subject {{ text-align: center; font-size: 14pt; font-weight: bold; text-decoration: underline; text-decoration-thickness: 2px; text-underline-offset: 4px; margin: 30px 0; }}
.body p {{ text-indent: 1em; margin: 12px 0; }}
.body p.highlight {{ background: #fefae0; padding: 8px 12px; border-left: 3px solid #d4a017; margin: 16px 0; }}
.signature {{ margin-top: 50px; text-align: right; line-height: 1.6; }}
.signature .co {{ font-size: 13pt; font-weight: bold; }}
</style></head><body>

<div class="letter-head">
文書番号: {quote_no}<br/>
{fmt_jp_date(response_date)}
</div>

<div class="to">BPS株式会社<br/>購買部 御中</div>

<div class="subject">お見積のご案内</div>

<div class="body">
<p>拝啓 春暖の候、貴社益々ご清栄のこととお慶び申し上げます。平素は格別のご高配を賜り、厚く御礼申し上げます。</p>

<p>このたびはP-IDP-TEST-001 電源モジュールのお見積につきまして、お引き合いを賜り誠にありがとうございます。下記の通り、弊社からの条件をご提示申し上げますので、ご査収のほどよろしくお願い申し上げます。</p>

<p class="highlight">ご提示単価は税抜 <b>¥{unit_price:,}</b> にて承ります。お取引は <b>{moq:,}個</b> 単位でのご発注をお願いしており、ご発注より <b>{lead_days}日</b> でお届け可能です。製造は弊社 <b>{mfg_site}</b> にて実施いたします。</p>

<p>なお、本お見積の有効期限は <b>{fmt_jp_date(valid_until)}</b> までとさせていただきます。ご不明な点がございましたら、担当までお気軽にお問い合わせください。</p>

<p>ご検討のほど、何卒よろしくお願い申し上げます。</p>

<p style="text-align:right;margin-top:20px">敬具</p>
</div>

<div class="signature">
<div class="co">{supplier}</div>
<div>営業部 田中太郎</div>
<div>TEL: 052-xxx-xxxx</div>
</div>

</body></html>
"""


# ============================================================
# 04: Mixed Japanese/English grid layout (with price discrepancy)
# ============================================================
def build_english_grid(supplier, unit_price, lead_days, moq, mfg_site, valid_until, response_date, quote_no, **_):
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>QUOTATION {quote_no}</title>
<style>
@page {{ size: A4; margin: 15mm; }}
body {{ font-family: "Helvetica", "Arial", "Hiragino Sans", sans-serif; color: #222; font-size: 10pt; }}
.top-bar {{ background: linear-gradient(90deg, #1e3a5f 0%, #2c5282 100%); color: #fff; padding: 16px 20px; display: flex; justify-content: space-between; align-items: center; }}
.top-bar h1 {{ margin: 0; font-size: 20pt; letter-spacing: 0.1em; font-weight: 300; }}
.top-bar .sub {{ font-size: 9pt; opacity: 0.9; }}
.meta-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; padding: 16px 20px; background: #f5f7fa; font-size: 9.5pt; }}
.meta-grid .lbl {{ color: #666; font-size: 8pt; text-transform: uppercase; letter-spacing: 0.05em; }}
.meta-grid .val {{ font-weight: 600; margin-top: 2px; }}
.items-grid {{ width: 100%; border-collapse: collapse; margin: 16px 0 0 0; }}
.items-grid th {{ background: #1e3a5f; color: #fff; padding: 10px; font-weight: 500; font-size: 9pt; text-transform: uppercase; letter-spacing: 0.05em; }}
.items-grid td {{ padding: 12px 10px; border-bottom: 1px solid #ddd; font-size: 10pt; }}
.items-grid td.num {{ text-align: right; font-family: "Menlo", monospace; }}
.subgrid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 1px; background: #ddd; margin: 20px 20px 16px 20px; border: 1px solid #ddd; }}
.subgrid .cell {{ background: #fff; padding: 10px 14px; font-size: 10pt; }}
.subgrid .cell .lbl {{ color: #666; font-size: 8pt; text-transform: uppercase; letter-spacing: 0.05em; }}
.subgrid .cell .val {{ font-weight: 600; margin-top: 3px; }}
.footer-note {{ margin: 16px 20px; padding: 8px 12px; background: #fef9c3; border-left: 3px solid #eab308; font-size: 8.5pt; color: #713f12; }}
</style></head><body>

<div class="top-bar">
<div><h1>QUOTATION</h1><div class="sub">御 見 積 書</div></div>
<div style="text-align:right"><div class="sub">Ref.</div><div style="font-size:12pt">{quote_no}</div></div>
</div>

<div class="meta-grid">
<div><div class="lbl">Supplier / 発行元</div><div class="val">{supplier}</div></div>
<div><div class="lbl">Issue Date / 発行日</div><div class="val">{response_date}</div></div>
<div><div class="lbl">Contact</div><div class="val">Tanaka, Sales Dept.</div></div>
<div><div class="lbl">Customer / 宛先</div><div class="val">BPS Co., Ltd. Procurement</div></div>
</div>

<table class="items-grid">
<tr><th>Part No. / 品番</th><th>Description</th><th>Unit Price (税抜)</th><th>Qty</th><th>Amount</th></tr>
<tr>
<td>P-IDP-TEST-001</td>
<td>Power Module<br/><span style="color:#888;font-size:9pt">電源モジュール</span></td>
<td class="num">JPY {unit_price:,}</td>
<td class="num">{moq:,}</td>
<td class="num">JPY {unit_price*moq:,}</td>
</tr>
</table>

<div class="subgrid">
<div class="cell"><div class="lbl">Lead Time / 納期</div><div class="val">{lead_days} days</div></div>
<div class="cell"><div class="lbl">MOQ / 最小発注数量</div><div class="val">{moq:,} units</div></div>
<div class="cell"><div class="lbl">Mfg Site / 製造拠点</div><div class="val">{mfg_site}</div></div>
<div class="cell"><div class="lbl">Valid Until / 有効期限</div><div class="val">{valid_until}</div></div>
</div>

<div class="footer-note">※ Prices are tax-excluded. Payment terms: end-of-month + 30 days, bank transfer.</div>

</body></html>
"""


# ============================================================
# 05: Narrow receipt/invoice style (with date discrepancy)
# ============================================================
def build_compact_receipt(supplier, unit_price, lead_days, moq, mfg_site, valid_until, response_date, quote_no, **_):
    return f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8"><title>見積書 {quote_no}</title>
<style>
@page {{ size: A4; margin: 20mm 60mm; }}
body {{ font-family: "Hiragino Sans", sans-serif; color: #000; font-size: 10.5pt; }}
.receipt-border {{ border: 2px solid #000; padding: 0; }}
.receipt-header {{ text-align: center; padding: 12px 8px; border-bottom: 2px solid #000; background: #222; color: #fff; }}
.receipt-header h1 {{ margin: 0; font-size: 16pt; letter-spacing: 0.3em; }}
.receipt-header .sub {{ font-size: 9pt; opacity: 0.85; margin-top: 2px; letter-spacing: 0.1em; }}
.issue {{ text-align: center; padding: 10px; font-size: 10pt; border-bottom: 1px dashed #999; }}
.section {{ padding: 8px 16px; border-bottom: 1px dashed #999; }}
.section .title {{ font-size: 8.5pt; color: #777; letter-spacing: 0.15em; margin-bottom: 3px; }}
.section .body {{ font-size: 11pt; font-weight: bold; }}
.kv-line {{ display: flex; justify-content: space-between; padding: 6px 16px; border-bottom: 1px dashed #ccc; font-size: 10pt; }}
.kv-line:last-child {{ border-bottom: none; }}
.kv-line .k {{ color: #555; }}
.kv-line .v {{ font-weight: 600; }}
.separator {{ text-align: center; padding: 6px 0; color: #999; letter-spacing: 0.4em; font-size: 9pt; background: #f5f5f5; }}
.footer-thanks {{ text-align: center; padding: 12px 8px; font-size: 9pt; color: #666; background: #fafafa; }}
</style></head><body>

<div class="receipt-border">

<div class="receipt-header">
<h1>見積書</h1>
<div class="sub">ESTIMATE / RECEIPT</div>
</div>

<div class="issue">発行: {fmt_jp_date(response_date)}<br/>No.{quote_no}</div>

<div class="section">
<div class="title">発 行 元</div>
<div class="body">{supplier}</div>
<div style="font-size:9pt;color:#666;margin-top:2px">営業部 田中太郎</div>
</div>

<div class="separator">─ 明 細 ─</div>

<div class="kv-line"><span class="k">品番</span><span class="v">P-IDP-TEST-001</span></div>
<div class="kv-line"><span class="k">数量</span><span class="v">{moq:,}</span></div>
<div class="kv-line"><span class="k">値段</span><span class="v">¥{unit_price:,}</span></div>
<div class="kv-line"><span class="k">工期</span><span class="v">{lead_days}日</span></div>
<div class="kv-line"><span class="k">最少発注</span><span class="v">{moq:,}</span></div>
<div class="kv-line"><span class="k">製造地</span><span class="v">{mfg_site}</span></div>
<div class="kv-line"><span class="k">有効</span><span class="v">{fmt_jp_date(valid_until)}</span></div>

<div class="footer-thanks">ご検討のほど何卒よろしくお願い申し上げます</div>

</div>

</body></html>
"""


# ============================================================
# Sample definitions
# ============================================================
BASE = dict(
    supplier="東亜電子工業",
    unit_price=4800,
    lead_days=45,
    moq=1000,
    mfg_site="東亜電子 本社工場",
    valid_until="2026-07-31",
    response_date="2026-04-20",
)


SAMPLES = [
    # 1. Traditional letterhead, baseline values → 🟢 全一致
    ("01-formal-letterhead.html", build_formal_letterhead,
     {**BASE, "quote_no": "Q-2026-0420"}),

    # 2. Compact fax, baseline values (different labels) → 🟢 全一致
    ("02-simple-fax.html", build_simple_fax,
     {**BASE, "quote_no": "FAX-20260420"}),

    # 3. Narrative letter, baseline values (prose) → 🟢 全一致
    ("03-narrative-letter.html", build_narrative_letter,
     {**BASE, "quote_no": "TD-EST-26042001"}),

    # 4. Japanese/English grid, PRICE DIFFERENT (4,500 vs 4,800) → 🔴 単価致命差
    ("04-english-grid.html", build_english_grid,
     {**BASE, "quote_no": "QTN-2026-0423", "unit_price": 4500}),

    # 5. Compact receipt, DATES DIFFERENT (2028) → 🔴 日付致命差
    ("05-compact-receipt.html", build_compact_receipt,
     {**BASE, "quote_no": "R-28042001",
      "valid_until": "2028-07-31", "response_date": "2028-04-20"}),
]


def main() -> None:
    for filename, builder, data in SAMPLES:
        html = builder(**data)
        (DIR / filename).write_text(html, encoding="utf-8")
        print(f"Wrote {filename}")


if __name__ == "__main__":
    main()
