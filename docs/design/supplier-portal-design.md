# サプライヤーポータル（Experience Cloud）設計書

## 1. 目的

SRM（サプライヤー関係管理）のうち、サプライヤーと直接双方向でやり取りすべき業務領域を Experience Cloud 上のサプライヤーポータルとして公開する。社内担当者の電話・メール往復を削減し、見積回答・キャパシティ申告・品質調査回答を **セルフサービス化** する。

## 2. 公開対象オブジェクト

### 2.1 公開する（ポータル内で閲覧・編集）

| オブジェクト | 公開理由 | サプライヤー操作 |
|---|---|---|
| RFQ__c | 見積依頼内容の確認 | 閲覧のみ |
| RFQ_Quote__c | 見積回答の提出・更新 | 作成・編集・提出 |
| Supplier_Capacity__c | 月産能力の申告とメンテナンス | 作成・編集 |
| Supplier_Investigation__c | 品質調査への回答（原因・対策） | 限定編集（回答欄のみ） |
| Supplier_Certification__c | 保有認証の申告・更新 | 作成・編集 |
| Manufacturing_Site__c | 製造拠点情報のメンテナンス | 作成・編集（限定） |

### 2.2 公開しない

| オブジェクト | 非公開理由 |
|---|---|
| Supplier_Audit__c | 社内主導の監査プロセス。是正進捗は Investigation に集約 |
| Supplier_Part__c | 社内マスタ。サプライヤー側の編集は混乱の元 |
| Corrective_Action__c | 8Dプロセスは社内主導。サプライヤー関与は Investigation 経由に一本化 |

### 2.3 BOM情報の露出範囲（重要）

Supplier_Investigation / RFQ から参照される BOM_Part__c は、**品番（Part_Number__c）と品名（Part_Name__c）のみ表示**し、BOM構造（親子関係・SubComponent 等）は公開しない。デモ時のわかりやすさを確保しつつ、実務で問題となる設計情報の流出を防ぐ前提。

## 3. 権限・共有モデル（デモ前提）

- デモでは **特定のサプライヤーAccountに紐づくユーザー1名** でアクセスする前提
- 実運用では Sharing Set（Experience Cloudの標準機能）で「ユーザーのAccount = Supplier__c」のレコードのみ見える構成を想定
- Permission Set（例: `Supplier_Portal_User`）に以下を含める:
  - 対象オブジェクトの Read / Create / Edit 権限
  - 編集禁止フィールド（Status の社内側遷移など）は FLS で制御
- Account（Supplier企業）の標準オブジェクト権限は **自社レコードのみ** 見える構成

## 4. ポータル全体のページ構成

```
[サプライヤーポータル]
  │
  ├─ Home              … 大型ダッシュボードLWC（入口）
  │
  ├─ RFQ               … 見積依頼一覧 / 詳細 / 回答フォーム
  │    └─ Detail: RFQ + 自社RFQ_Quote 編集
  │
  ├─ Capacity          … 拠点×品目のキャパシティ管理
  │
  ├─ Investigation     … 品質調査一覧 / 回答フォーム
  │    └─ Detail: 原因分析・対策入力
  │
  ├─ Certification     … 保有認証一覧 / 新規申告
  │
  └─ Sites             … 製造拠点一覧 / 新規追加・住所更新
```

ナビゲーションは Experience Cloud 標準の Navigation Menu を利用。

## 5. LWC 一覧（Wave 1）

| # | LWC名 | 配置先 | 主要機能 |
|---|---|---|---|
| 1 | `supplierPortalHome` | Home | ダッシュボード。未対応RFQ/調査件数、期限アラート、認証・キャパ状況 |
| 2 | `rfqQuoteResponseForm` | RFQ Detail | RFQ内容の表示＋自社Quote入力／更新、ステータス遷移 |
| 3 | `supplierCapacityManager` | Capacity | 拠点×品目のキャパ一覧、インライン編集、新規追加 |
| 4 | `supplierInvestigationResponse` | Investigation Detail | 調査要件表示＋Root_Cause/Action_Taken入力、進捗遷移 |
| 5 | `supplierCertificationList` | Certification | 認証一覧（ステータス色分け）、新規申告フォーム |
| 6 | `manufacturingSiteManager` | Sites | 拠点一覧＋マップ、新規追加、住所更新 |

RFQ 一覧は `supplierPortalHome` の一部 or `lightning-record-list` で代替するため、独立LWCは作らない想定。必要に応じて追加。

## 6. ホームダッシュボード詳細仕様

### 6.1 目的

サプライヤーがログインしたときに **「今日、自分が何をすべきか」** が一目でわかるタスク駆動ダッシュボード。

### 6.2 レイアウト案

```
┌──────────────────────────────────────────────────────────────┐
│  [挨拶] こんにちは、[サプライヤー名] 様                     │
│  [最終ログイン: yyyy/mm/dd hh:mm]                            │
├──────────────────────────────────────────────────────────────┤
│  ┌─── アクション必要 ─────────────────────────────────────┐ │
│  │ ① 未回答RFQ      [N件]  最短期限: yyyy/mm/dd           │ │
│  │ ② 調査対応中     [N件]  最短期限: yyyy/mm/dd           │ │
│  │ ③ 期限切れ間近認証 [N件]  最短: 残Xd                   │ │
│  │ ④ キャパ未更新拠点 [N件]  前回更新: yyyy/mm/dd         │ │
│  └────────────────────────────────────────────────────────┘ │
├──────────────────────────────────────────────────────────────┤
│  ┌── RFQ進行状況 ───┐  ┌── 調査対応状況 ───┐                │
│  │ 下書き | 発行済  │  │ ステータス別       │                │
│  │ 評価中 | 決定済  │  │ 件数バーチャート   │                │
│  │ (ドーナツ)       │  │                    │                │
│  └──────────────────┘  └────────────────────┘                │
├──────────────────────────────────────────────────────────────┤
│  ┌── 供給キャパシティサマリー ──────────────────────────┐    │
│  │ 拠点A: 月産1,200 [有効期限: 2026/06/30] [●●●●●]      │    │
│  │ 拠点B: 月産  800 [有効期限: 2026/03/31 ⚠] [●●●●○]   │    │
│  └──────────────────────────────────────────────────────┘    │
├──────────────────────────────────────────────────────────────┤
│  ┌── 保有認証 ───────┐  ┌── 最新RFQリスト ──────────────┐    │
│  │ ISO9001 [有効]    │  │ RFQ-0001 DC-Motor   期限: ... │    │
│  │ IATF16949 [更新中]│  │ RFQ-0012 Shaft-A    期限: ... │    │
│  │ ISO14001 [期限切]│  │ ...                           │    │
│  └───────────────────┘  └────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### 6.3 表示要素の詳細

| ブロック | データソース | 表示方法 |
|---|---|---|
| アクションKPIカード×4 | 条件付きSOQLカウント | 大型の数字＋クリックで遷移 |
| RFQ進行ドーナツ | RFQ_Quote by Status | SLDSチャート or SVG |
| 調査対応バー | Investigation by Status | シンプルなバー表示 |
| キャパシティサマリー | Capacity（自社拠点の最新） | プログレスバー＋有効期限警告 |
| 保有認証 | Certification（全件） | ステータスバッジ＋期限カウントダウン |
| 最新RFQ | RFQ（自社宛＋期限昇順TOP5） | リスト＋リンク |

### 6.4 デザインガイドライン

- SLDS（Salesforce Lightning Design System）ベース＋カスタムCSSトークン
- **BPSブランドカラー**（`#D21D24`）をアクセント限定で使用。低コントラスト・白ベース基調
- 情報密度: **高め**でOK（ユーザー指示）
- レスポンシブ: PC中心だがタブレット幅でも崩れないグリッド

#### カラーパレット（全LWC共通）

| 用途 | 色 | 備考 |
|---|---|---|
| ページ背景 | `#FAFAFA` | 全体の地色 |
| カード背景 | `#FFFFFF` | コンテンツブロック |
| 主要見出し文字 | `#2D2D2D` | 純黒回避 |
| 本文 | `#555555` | 長文でも疲れない |
| ブランドアクセント（primary） | `#D21D24` | CTAボタン、重要KPI下線など **面積小限定** |
| アクセントhover/active | `#A61319` | ボタンhover等 |
| 薄アクセント背景 | `#FBEAEB` | 選択行、バッジ背景 |
| 中間アクセント | `#F2C0C2` | タブ下線、プログレス背景 |
| 期限警告・エラー | `#A61319` + アイコン | 赤基調のため記号で差別化 |
| 罫線・区切り | `#E5E5E5` | 薄い |

- チャート（ドーナツ・バー）は **単色濃淡**（`#FBEAEB` → `#F2C0C2` → `#D21D24` → `#A61319`）で統一
- ボタンは primary のみブランド赤、secondary は白＋グレー罫線
- ヘッダー・ロゴまわりはExperience Cloudのブランディングセット側で対応

## 7. データ取得方針

- Apex Controller: 1クラスに集約（例: `SupplierPortalController`）
- `@AuraEnabled(cacheable=true)` でホームダッシュボードの集計を一括取得
- 個別LWCは `getRecord` / `lightning-record-edit-form` を活用し、Apexを最小化
- サプライヤー特定は `UserInfo.getUserId()` → `User.AccountId` 経由でサプライヤーAccountを取得

## 8. Experience Cloud サイトの前提

- サイト種別: **LWR（Lightning Web Runtime）** 推奨（LWCネイティブ）
- サイト雛形作成はユーザー側で実施（ブラウザ操作必要）
- Claude側の作業範囲: ExperienceBundle メタデータ（ページ構成/ナビ/ブランディング）＋LWC＋Apex＋権限設定

## 9. Wave 1 開発順序

1. `supplierPortalHome` — 入口と全体ナビ確立
2. `rfqQuoteResponseForm` — 業務価値最大
3. `supplierCapacityManager` — 定期メンテ中核
4. `supplierInvestigationResponse` — 品質対応
5. `supplierCertificationList` — 認証申告
6. `manufacturingSiteManager` — 拠点メンテ

各LWC完成時に動作確認 → 次へ進む流れ。

## 10. オープン論点（後で決定）

- [ ] Experience Cloudサイトの実体作成タイミング（LWC開発後、デモ直前でも可）
- [ ] デモ用サプライヤーユーザーの作成（Permission Set割り当て含む）
- [ ] 共有設定（Sharing Set or Apex Managed Sharing）の実装タイミング
- [ ] RFQ通知（メール/Notification）は今回スコープ外とするか
- [ ] ファイル添付（見積書PDF、認証証書PDF）の扱い
