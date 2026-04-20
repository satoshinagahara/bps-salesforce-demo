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
