# IDP サプライヤー見積書 サンプルPDF

擬似IDP(Mulesoft IDP風機能)のデモ・動作確認用サンプル見積書PDF。

## 設計思想: レイアウトとラベルの多様性

IDPの本質的価値は **「レイアウトと項目名の違いを吸収して、事前定義スキーマ(JSON)に正規化する」** こと。
5サンプルは意図的に **互いに大きく異なるレイアウト・ラベル表現** を採用し、LLM(Claude Sonnet 4.6) が
どのフォーマットからも同じスキーマに正規化できることを実証する。

## 用途

- [idpQuoteFileUploader](../../force-app/main/default/lwc/idpQuoteFileUploader/) LWC の動作確認
- [idpQuoteDualEntry](../../force-app/main/default/lwc/idpQuoteDualEntry/) での比較判定
- 設計書: [docs/in-progress/idp-supplier-quote-design.md](../../docs/in-progress/idp-supplier-quote-design.md)

## サンプル一覧

| # | ファイル | レイアウト | ラベル戦略 | 値 | 期待される判定 |
|---|---|---|---|---|---|
| 1 | `01-formal-letterhead.pdf` | 伝統的な日本式御見積書(明朝体、発行元ボックス、表形式) | 標準日本語(**単価 / 納期 / 最小発注数量 / 製造拠点 / 見積有効期限 / 発行日**) | baseline | 🟢 全項目「一致」 |
| 2 | `02-simple-fax.pdf` | FAX風・無装飾・縦一列(サンセリフ、罫線のみ) | 略式日本語(**ユニット価格 / デリバリー / 最低ロット / 工場 / 期限**) | baseline | 🟢 全項目「一致」 |
| 3 | `03-narrative-letter.pdf` | ビジネス文書・散文(明朝体、敬具フォーマット) | **ラベル無し**、値を本文中に埋め込み | baseline | 🟢 全項目「一致」 |
| 4 | `04-english-grid.pdf` | モダンなグリッド(サンセリフ、ヘッダ帯、セル区切り) | 日英混在(**Unit Price / Lead Time / MOQ / Mfg Site / Valid Until / Issue Date**) | **単価 JPY 4,500** | 🔴 単価「致命差」 |
| 5 | `05-compact-receipt.pdf` | レシート風・縦長短冊(黒ヘッダ、破線区切り) | 簡潔日本語(**値段 / 工期 / 最少発注 / 製造地 / 有効**) | **発行日 2028-04-20 / 有効期限 2028-07-31** | 🔴 日付「致命差」 |

## 期待するIDP挙動

サンプル1-3は **同じ値** を **全く違うレイアウト・ラベル** で表現。
Claude Sonnet 4.6 が全サンプルから以下の同一スキーマに抽出できれば、レイアウト非依存の証明になる:

```json
{
  "supplier_name": {"value": "東亜電子工業", "confidence": 0.95},
  "unit_price": {"value": 4800, "confidence": 0.98},
  "lead_time_days": {"value": 45, "confidence": 0.95},
  "moq": {"value": 1000, "confidence": 0.95},
  "manufacturing_site": {"value": "東亜電子 本社工場", "confidence": 0.95},
  "valid_until": {"value": "2026-07-31", "confidence": 0.95},
  "response_date": {"value": "2026-04-20", "confidence": 0.95}
}
```

サンプル4-5は **レイアウト多様性 + 値の意図的な乖離** により、ダブルチェック判定の価値もあわせて実演。

## 想定される人間入力値(デモ時の前提)

テスト用 `RFQ_Quote__c` レコード `a2xIe000000Go5QIAS` (QT-0032) の人間入力値:

| 項目 | 人間入力値 |
|---|---|
| サプライヤー | 東亜電子工業 (Account Lookup, RecordType: サプライヤー) |
| 単価 | ¥4,800 |
| 納期日数 | 45 |
| MOQ | 1,000 |
| 製造拠点 | 東亜電子 本社工場 (Manufacturing_Site Lookup) |
| 有効期限 | 2026-07-31 |
| 回答日 | 2026-04-20 |

## 再生成方法

```bash
cd test-data/idp-supplier-quotes
python3 _build_html.py   # HTMLを再生成(値・レイアウトを変えたい時)
./generate.sh            # HTML → PDF (Chrome headless)
```

`_build_html.py` では各レイアウトを独立した関数として定義しているため、
新しいレイアウト(6th sample等)の追加も容易。
