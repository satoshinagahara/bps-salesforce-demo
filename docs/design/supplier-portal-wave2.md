# サプライヤーポータル Wave 2 — メニュー拡張・ルート再設計

Wave 1 完了後、**見積依頼一覧 / 品質調査一覧** を独立したメニュー項目として公開するための改修。

## 1. 目的

Wave 1 ではホームダッシュボード内にインライン表示していた RFQ / 品質調査の回答フォームを、**独立したポータルメニュー項目**として切り出す。

- ホーム: ダッシュボード（KPI・チャート・キャパサマリー）＋ メニュー遷移の入口のみ
- `/rfq-list`: RFQ 一覧 ⇔ 回答フォーム（ビュー切替パターン）
- `/investigation-list`: 品質調査一覧 ⇔ 回答フォーム（ビュー切替パターン）

## 2. 成果物

### 2.1 新規 LWC

| LWC | ルート | 内包コンポーネント | 主要機能 |
|---|---|---|---|
| `supplierRfqList` | `/rfq-list` | `c:rfqQuoteResponseForm` | フィルター付き一覧 / 行クリックで回答フォームに切替 |
| `supplierInvList` | `/investigation-list` | `c:supplierInvestigationResponse` | フィルター付き一覧 / 行クリックで回答フォームに切替 |

**ビュー切替パターン**:
```
viewMode = 'list' | 'respond'
onRowClick → selectedId を保持 → viewMode='respond' で子 LWC に渡す
onBackToList → viewMode='list' → refreshApex
```

### 2.2 Apex 追加

`SupplierPortalController`:
- `getRfqList(Id accountId, String filter)` — `all / pending / answered / closed`、LIMIT 200
- `getInvestigationList(Id accountId, String filter)` — `all / ongoing / responded / completed`
- 戻り値 DTO: `RfqListDTO` / `InvestigationListDTO`（totalCount + ステータス別カウント + 行データ）

### 2.3 supplierPortalHome のリファクタ

- インライン回答フォーム描画を削除
- KPI カード・認証リスト・RFQリスト等の **ドリルダウン UI を削除**
- 代わりに `NavigationMixin.Navigate`（`standard__webPage` + 相対 URL）で各メニュー項目へ遷移
- 責務を「ダッシュボード＋メニュー入口」に限定

### 2.4 ExperienceBundle 変更

| 変更 | 内容 |
|---|---|
| 追加 | `routes/見積依頼一覧.json` (routeType=`quote-list`, urlPrefix=`rfq-list`) |
| 追加 | `views/見積依頼一覧.json` (viewType=`quote-list`, component=`c:supplierRfqList`) |
| 追加 | `routes/品質調査一覧.json` (routeType=`case-list`, urlPrefix=`investigation-list`) |
| 追加 | `views/品質調査一覧.json` (viewType=`case-list`, component=`c:supplierInvList`) |
| 削除 | `routes/rFQ見積回答.json` / `views/rFQ見積回答.json`（Wave 1 の単独ページを supersede） |
| 削除 | `routes/調査回答.json` / `views/調査回答.json`（同上） |
| 残置 | `routes/enablementProgramLink.json` / `enablementProgramVideo.json`（テンプレートが構造的に要求するスタブルート） |

### 2.5 NavigationMenuItem

`SRMポータル` (NavigationLinkSet=`Default_Navigation15`) の Live メニュー構成:

| Position | Label | Target |
|---|---|---|
| 1 | 見積依頼 | `/rfq-list` |
| 2 | 品質調査 | `/investigation-list` |
| 3 | 製造拠点 | `/sites` |
| 4 | 生産キャパシティ | `/capacity` |
| 5 | 認証・資格 | `/certifications` |

## 3. 実装中に判明した制約（再利用可能な知見）

`docs/reference/known-issues.md` の **Experience Cloud (Partner Central Enhanced)** セクションに反映済み。要点:

- Partner Central Enhanced テンプレートは特定の `routeType`（`enablement-program-link/-video` 等）の route が必ず存在することを要求 → 完全削除不可、最小スタブで残す
- `enablement-program-*` 系 routeType は `urlPrefix` 単独では NavigationMenuItem から到達不可（recordId 必須のドリルダウン扱い）→ 乗っ取り先候補から除外
- URL アドレス可能な乗っ取り先 routeType: `quote-list`, `case-list`, `jointbusinessplan-list`, `voucher-list`, `mdf` （本 demo org で動作確認済）
- NavigationMenuItem 作成前に `sf community publish` が必須。未 publish だと「URL パスのサイトにページが見つかりません」
- NavigationMenuItem の Position はステータス内で一意。衝突する場合は逆順（大→小）でシフト
- routes/views は 1:1 対応（`activeViewId` ↔ `view.id` / `routeType` ↔ `viewType`）。孤立 view はデプロイエラー

## 4. デプロイ手順（再現用）

```bash
sf project deploy start --target-org $TARGET_ORG \
  --source-dir force-app/main/default/experiences/srm_wl4byf9crf1 \
  --source-dir force-app/main/default/lwc/supplierRfqList \
  --source-dir force-app/main/default/lwc/supplierInvList \
  --source-dir force-app/main/default/lwc/supplierPortalHome \
  --source-dir force-app/main/default/classes/SupplierPortalController.cls \
  --ignore-conflicts

sf community publish --target-org $TARGET_ORG --name "SRMポータル"

# 既存 Draft メニュー項目を逆順で Position シフト（大→小の順で衝突回避）
# → 新規 Draft 項目を Position 1, 2 で作成
# → sf community publish で Draft → Live 昇格
```

## 5. 残置課題

- Wave 1 で残っていた壊れた `/rfq-response` `/investigation-response` ページは Wave 2 で **完全除去済**
- テンプレートが要求する `enablement-program-*` スタブルートは残置（2 本、害なし）

## 6. ヘッダー / フッター HTML（Experience Builder 貼付用）

Experience Builder の「リッチコンテンツエディタ」に HTML モードで貼り付ける想定。LWC で既に構築済のダッシュボードと重複しない情報として、**ヘッダーはサポート窓口** を常時可視化し、**フッターは規約/問い合わせ動線** を全ページ共通で提供する。

### 6.1 ヘッダー（ホームのみ、高さ ~200px）

- 背景: Experience Cloud 標準の `/sfsites/assets/Images/PrmEnhancedBanner/PrmEnhancedBanner.png`
- 左右グラデーションの白オーバーレイでテキスト可読性確保
- 下端に BPS 赤 4px アクセント
- 右側にサポート窓口カード（角丸 14px、白背景＋赤影）

```html
<div style="position:relative;width:100%;min-height:200px;overflow:hidden;font-family:'Hiragino Sans','Noto Sans JP',sans-serif;border-bottom:4px solid #D21D24;box-sizing:border-box;">

  <img src="/sfsites/assets/Images/PrmEnhancedBanner/PrmEnhancedBanner.png" alt="" style="position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover;z-index:1;" />

  <div style="position:absolute;top:0;left:0;width:100%;height:100%;background:linear-gradient(90deg,rgba(255,255,255,0.75) 0%,rgba(255,255,255,0.55) 45%,rgba(255,255,255,0.25) 100%);z-index:2;"></div>

  <div style="position:relative;z-index:3;display:flex;align-items:center;justify-content:space-between;padding:1.75rem 2.5rem;gap:2rem;flex-wrap:wrap;min-height:200px;box-sizing:border-box;">

    <div style="flex:1 1 320px;min-width:280px;">
      <div style="display:inline-block;padding:0.2rem 0.7rem;background:#D21D24;color:#FFFFFF;font-size:0.72rem;font-weight:700;letter-spacing:0.1em;border-radius:2px;margin-bottom:0.7rem;">SUPPLIER PORTAL</div>
      <h1 style="margin:0 0 0.45rem 0;font-size:1.65rem;font-weight:700;color:#2D2D2D;line-height:1.3;text-shadow:0 1px 2px rgba(255,255,255,0.6);">サプライヤーポータルへようこそ</h1>
      <p style="margin:0;font-size:0.92rem;color:#444444;line-height:1.5;text-shadow:0 1px 2px rgba(255,255,255,0.6);">日々のご対応ありがとうございます。見積依頼・品質調査への対応状況はダッシュボードからご確認ください。</p>
    </div>

    <div style="flex:0 0 auto;min-width:260px;background:#FFFFFF;border:1px solid #F2C0C2;border-radius:14px;padding:1rem 1.25rem;box-shadow:0 4px 12px rgba(210,29,36,0.15);">
      <div style="font-size:0.72rem;font-weight:700;color:#D21D24;letter-spacing:0.08em;margin-bottom:0.5rem;">BPS サプライヤーサポート窓口</div>
      <div style="display:flex;flex-direction:column;gap:0.3rem;font-size:0.85rem;color:#2D2D2D;line-height:1.4;">
        <div><span style="color:#888;display:inline-block;width:3.5em;">TEL</span><span style="font-weight:600;">03-0000-0000</span></div>
        <div><span style="color:#888;display:inline-block;width:3.5em;">Mail</span><a href="mailto:supplier-support@bps.example.com" style="color:#A61319;text-decoration:none;font-weight:600;">supplier-support@bps.example.com</a></div>
        <div style="color:#888;font-size:0.78rem;margin-top:0.15rem;">受付時間: 平日 9:00–17:30</div>
      </div>
    </div>

  </div>
</div>
```

### 6.2 フッター（全ページ共通）

- 上端に BPS 赤 2px アクセント
- 左: サービス名＋著作権表記
- 右: 規約/プライバシー/FAQ/問い合わせリンク（規約系は `href="#"` プレースホルダ、実運用で差し替え）
- 下端に黒帯でバージョン・最終更新日

```html
<div style="width:100%;border-top:2px solid #D21D24;background:#FAFAFA;font-family:'Hiragino Sans','Noto Sans JP',sans-serif;color:#555555;box-sizing:border-box;">
  <div style="max-width:1400px;margin:0 auto;padding:1.25rem 2rem;display:flex;justify-content:space-between;align-items:center;gap:1.5rem;flex-wrap:wrap;">

    <div style="display:flex;align-items:center;gap:1rem;flex-wrap:wrap;">
      <span style="font-size:0.82rem;color:#2D2D2D;font-weight:600;">BPS Supplier Portal</span>
      <span style="font-size:0.75rem;color:#888;">© 2026 BPS Corporation. All rights reserved.</span>
    </div>

    <div style="display:flex;align-items:center;gap:1.5rem;font-size:0.8rem;flex-wrap:wrap;">
      <a href="#" style="color:#555555;text-decoration:none;">利用規約</a>
      <span style="color:#E5E5E5;">|</span>
      <a href="#" style="color:#555555;text-decoration:none;">プライバシーポリシー</a>
      <span style="color:#E5E5E5;">|</span>
      <a href="#" style="color:#555555;text-decoration:none;">ヘルプ / FAQ</a>
      <span style="color:#E5E5E5;">|</span>
      <a href="mailto:supplier-support@bps.example.com" style="color:#A61319;text-decoration:none;font-weight:600;">お問い合わせ</a>
    </div>

  </div>

  <div style="background:#2D2D2D;color:#999;font-size:0.7rem;padding:0.5rem 2rem;text-align:center;letter-spacing:0.03em;">
    Portal Version 2.0　|　最終更新: 2026-04-20
  </div>
</div>
```

### 6.3 配置手順

1. Experience Builder > ホームページ > **リッチコンテンツエディタ** をヘッダー領域にドラッグ → HTML モード → ヘッダー HTML 貼付
2. テンプレート/テーマの Footer 領域（全ページ共通）にリッチコンテンツエディタを配置 → フッター HTML 貼付
3. `sf community publish` で反映
