# Supplier Portal Wave 1 — 最終設定手順書

Wave 1 LWC 実装・デプロイ・ポータルユーザ作成まで完了。本ドキュメントは残りの **UI のみ対応が必要な設定** と、**Experience Cloud サイト上へのコンポーネント配置手順** をまとめる。

---

## 1. 完了済み（自動化済み）

### 1.1 Apex / LWC

| 項目 | 状態 | 備考 |
|---|---|---|
| `SupplierPortalController.cls` | ✅ デプロイ済 | Wave 1 全メソッド実装（Site/Cert/Investigation CRUD含む） |
| `supplierPortalHome` LWC | ✅ デプロイ済 | ダッシュボード・サマリー |
| `rfqQuoteResponseForm` LWC | ✅ デプロイ済 | RFQ見積回答フォーム |
| `supplierCapacityManager` LWC | ✅ デプロイ済 | 生産キャパシティ管理 |
| `supplierInvestigationResponse` LWC | ✅ デプロイ済 | 品質調査回答フォーム |
| `supplierCertificationList` LWC | ✅ デプロイ済 | 認証・資格管理 |
| `manufacturingSiteManager` LWC | ✅ デプロイ済 | 製造拠点マップ＋CRUD |

### 1.2 権限セット

- `Supplier_Portal_Access`（License: Partner Community）デプロイ済
- Wave 1 で必要な最小限の Object/Field 権限 + Apex クラス権限を含む
- 必須項目（Required）は権限セットで明示不可のため除外済（プロファイル側で付与済の前提）

### 1.3 Experience Cloud 全体設定

- Communities Settings > `enableOotbProfExtUserOpsEnable` = **true** デプロイ済
  （= 「セルフ登録、ユーザ作成、およびログインで標準外部プロファイルの使用を許可」）

### 1.4 Account / Contact / User

| 項目 | 値 |
|---|---|
| Account | グリーンエナジーセル（`001Ie00000Aq4lsIAB`） — `IsPartner=true` に昇格済 |
| Contact | 吉田 隆（`003Ie000008UAQCIA4`） |
| User | `yoshida1776431632685@greenenergy.demo.sfdc`（`005Ie000000IXAvIAO`） |
| Profile | Partner Community User |
| PermissionSet | Supplier_Portal_Access 割当済 |

### 1.5 デモデータ

- 堺工場 = 自社拠点（`Is_Own_Site__c=true`）
- 四国工場 = 協力会社拠点（`Is_Own_Site__c=false`）
- Supplier_Investigation レコード 6件（SI-0001〜SI-0006）
- Supplier_Certification レコード 4件（有効1/期限間近1/期限切れ2）
- Supplier_Capacity レコード 複数
- Manufacturing_Site レコード 2件

---

## 2. UI 操作が必要な残タスク

### 2.1 Sharing Set 設定（UI のみ）

Portal ユーザが自社（グリーンエナジーセル）に紐づくレコードのみを閲覧・編集できるようにするため、Sharing Set を作成する。

**操作手順**:

1. Setup > Digital Experiences > All Sites > **SRMポータル**（UrlPathPrefix=`srm2`）> Workspaces > Administration > **Sharing Settings** をクリック
2. 「Sharing Sets」セクションで **New** をクリック
3. 以下を入力:

| 項目 | 値 |
|---|---|
| Label | Supplier Own Records |
| Sharing Set Name | Supplier_Own_Records |
| Description | サプライヤーは自社関連レコードのみ参照可能 |
| Profiles | Partner Community User |
| Object | 下記の各オブジェクトに対して Access Mapping を追加 |

4. **Access Mapping** 追加（各オブジェクトごと）:

| Object | User: Contact | Target: Source Field | Access |
|---|---|---|---|
| RFQ_Quote__c | `Contact.AccountId` | `Supplier__c` | Read/Write |
| Supplier_Capacity__c | `Contact.AccountId` | `Manufacturing_Site__r.Supplier__c` | Read/Write |
| Supplier_Investigation__c | `Contact.AccountId` | `Supplier__c` | Read/Write |
| Supplier_Certification__c | `Contact.AccountId` | `Supplier__c` | Read/Write |
| Manufacturing_Site__c | `Contact.AccountId` | `Supplier__c` | Read/Write |

5. **Save** で保存 → 即時反映

> **Note**: RFQ__c は RFQ_Quote__c 経由で間接参照するため Sharing Set 不要。ただし RFQ__c を直接閲覧するには Community 側で Manual/Criteria-Based Sharing Rule を別途検討。

### 2.2 Experience Cloud サイトページ設定

**対象サイト**: SRMポータル（UrlPathPrefix=`srm2`）

> **補足**: もう一つの「サプライヤーポータル」(`srm`) は古い検証用。本番デモでは `srm2` を使う。

#### 手順

1. Setup > Digital Experiences > All Sites > **SRMポータル** > **Builder** をクリック
2. 左メニューから **Pages** を選択し、以下のページを追加/編集する

#### 2.2.1 ホーム（`/`）

- 既存の Home ページを編集
- Components パネルから **Supplier Portal Home** をドラッグ＆ドロップ
- プロパティは `accountId` を空のまま（LWC 側で currentUser.AccountId を内部取得するため） or ユーザの Account Id を自動注入

#### 2.2.2 RFQ 一覧＋見積回答（`/rfq` と `/rfq/:recordId`）

- New Page > **Standard Page** > RFQ_Quote__c の Object Page を作成
  - Page Type: Record Detail
  - Object: RFQ_Quote__c
- Detail ページの Tabs セクションに **RFQ Quote Response Form** を配置
- 引数は自動で `recordId` が渡る

#### 2.2.3 キャパシティ管理（`/capacity`）

- New Page > **Standard Page** > Blank
- Page Name: `capacity`, URL: `/capacity`
- **Supplier Capacity Manager** を配置
- `accountId` プロパティは空のまま（内部で currentUser.AccountId を使用）

#### 2.2.4 品質調査回答（`/investigation/:recordId`）

- Standard Page > Supplier_Investigation__c の Record Detail Page を作成
- **Supplier Investigation Response** を配置

#### 2.2.5 認証一覧（`/certifications`）

- New Page > Blank > `/certifications`
- **Supplier Certification List** を配置

#### 2.2.6 製造拠点（`/sites`）

- New Page > Blank > `/sites`
- **Manufacturing Site Manager** を配置

#### 2.2.7 ナビゲーションメニュー

1. Theme > Navigation Menu > **Edit**
2. 以下のメニュー項目を追加:

| Label | Type | URL/Object |
|---|---|---|
| ホーム | Community Page | Home |
| 見積回答 | Object | RFQ_Quote__c List |
| 生産キャパシティ | Community Page | /capacity |
| 品質調査 | Object | Supplier_Investigation__c List |
| 認証・資格 | Community Page | /certifications |
| 製造拠点 | Community Page | /sites |

3. **Publish** でサイト公開

### 2.3 デモログイン確認

ポータルユーザのパスワードは Portal Email Settings 未設定のためプログラム的にリセット不可。以下のいずれかで対応:

**方法 A: Setup から Login-As（推奨）**

1. Setup > Users > 吉田 隆（`yoshida1776431632685@greenenergy.demo.sfdc`）> **Login** リンクをクリック
2. そのセッションで Experience Cloud の Switcher から「SRMポータル」へアクセス

**方法 B: パスワード初期化**

1. Digital Experiences > All Sites > SRMポータル > Workspaces > Administration > **Emails** で送信者メールを設定
2. Setup > Users > 吉田 隆 > **Reset Password**
3. 登録メール（`yoshida@green-energy.example.com`）に初期化リンクが届く（デモ環境では実在しない場合あり）

---

## 3. 動作確認チェックリスト

- [ ] Sharing Set 作成後、他 Account の RFQ_Quote__c が見えないことを確認
- [ ] Portal ホームページで KPI カードが表示される
- [ ] RFQ 詳細ページで見積回答フォームが編集可能
- [ ] キャパシティ管理で自社拠点・協力会社別に表示される
- [ ] 品質調査ページで「依頼中」「調査中」は編集可、「回答済」は ReadOnly になる
- [ ] 認証一覧で有効/期限間近/期限切れで色分け表示される
- [ ] 製造拠点マップにピンが表示され、自社/協力会社が色分けされる

---

## 4. トラブルシューティング（実装中に遭遇した既知問題）

| 現象 | 対応 |
|---|---|
| PermissionSet に Required 項目を含めると「必須項目にはリリースできません」エラー | Required 項目は PermissionSet から除外。プロファイル側で自動付与される |
| PermissionSet の License 変更不可エラー | 一度 destructiveChanges で削除 → 新 License で再デプロイ |
| User 作成時「標準外部プロファイルの使用を許可」エラー | `CommunitiesSettings.enableOotbProfExtUserOpsEnable=true` をデプロイ |
| User 作成 + PermissionSetAssignment を同一 Apex で実行すると MIXED_DML_OPERATION | Apex スクリプトを 2段階に分割（User作成→PSA割当） |
| `System.resetPassword` / `setPassword` でポータルユーザ対象だと INSUFFICIENT_ACCESS | Emails 設定済ませるか、Setup の Login-As を使用 |
| User作成済なのに「このユーザーはどのエクスペリエンスサイトのメンバーでもありません」 | **NetworkMemberGroup** に Profile Id を insert（`sf data create record --sobject NetworkMemberGroup --values "NetworkId=... ParentId=..."`）。SRMポータル(`0DBIe000000fxrQOAQ`)にPartner Community User(`00eIe000000VUDbIAO`)追加済 |
| Setup > Users の「ログイン」リンクが表示されない | Experience CloudユーザーのLogin-AsはContact(取引先責任者)レコード右上「Log in as」ボタンが正規ルート。モーダルでサイト選択 |
| `sf org open --url-only` 生成の`/secur/frontdoor.jsp?otp=...` で「無操作状態のためログアウト」 | demo orgのMFA要件でotp短命。普段使いブラウザで管理者ログイン→Contact経由Login-Asが確実 |

---

## 5. 進捗メモ（2026-04-17 時点）

### 完了
- ✅ §2.1 Sharing Set（B-1 アプローチ）: `Supplier_Portal_Access` SharingSet メタデータデプロイ済。`Manufacturing_Site__c` / `Supplier_Certification__c` / `Corrective_Action__c` に Access Mapping 追加、ControlledByParent 伝播で `Supplier_Capacity__c` / `Supplier_Investigation__c` も自動カバー
- ✅ RFQ__c / BOM_Header__c の External OWD = **Read**（Public Read）に変更
- ✅ `SupplierPortalController` に `enforceQuoteOwnership` + `ElevatedOps`(inner without sharing class) 追加 → 所有権検証+Elevated Update
- ✅ `SupplierPortalSharingTest` で runAs() 動作確認済：自社2/他社0、RFQ Public Read動作、getDashboard 呼び出し成功
- ✅ SRMポータル(Network)のメンバーに Partner Community User プロファイル追加
- ✅ 専用ページ`/rfq-response` と `/investigation-response` 作成済（URL query param `rfqId` / `investigationId` 対応）
- ✅ ホーム画面に「対応中の品質調査」カードセクション追加

### 明日以降のテスト残
- [ ] 吉田 隆 Contact レコードから「Log in as」→ SRMポータル選択 で実際にログイン
- [ ] ホーム画面のKPI/RFQリスト/調査リスト表示確認
- [ ] RFQカード クリック → `/rfq-response?rfqId=...` 遷移 → 回答フォーム動作確認（下書き保存/回答提出/辞退）
- [ ] 調査カード クリック → `/investigation-response?investigationId=...` 遷移 → 回答動作確認
- [ ] §3 動作確認チェックリスト完了
- [ ] 他社（グリーンエナジーセル以外）のデータが見えないことを Login-As セッションで視覚確認

### 停止ポイント
前回会話の終わり：Contactレコード `003Ie000008UAQCIA4`（吉田 隆）のレコードページで「Log in as」モーダルを開き、「SRMポータル」選択肢が表示された状態。以降の実機テストは 2026-04-18 以降。

---

## 6. 進捗メモ（2026-04-19 時点）

### 今日の大きな出来事：`/srm2/s/login` の 503 障害とその打開

ブラウザで SRMポータル にアクセスすると `An unexpected connection error occurred. / This error originated from Salesforce CDN partner.` の 503 エラー（Akamai SNA failover ページ）が出る状態になっていた。**2 日連続で両サイト (srm/srm2) ともアクセス不能**。

#### 診断プロセス

| 試行 | 結果 |
|---|---|
| Builder → Publish リトライ | ❌ 503 継続 |
| ExperienceBundle retrieve + JSON検査 | ✅ メタデータは健全（全45JSON OK、orphan route ゼロ、LWC参照全件実在） |
| ローカル EB re-deploy | ❌ 503 継続 |
| Network Deactivate → Activate | ❌ 503 継続 |
| **curl での URL別ステータス確認** | ⭐ **犯人特定** |

#### 犯人特定（curl で切り分け）

```
/srm2/s/login     → 503 (Akamai SNA failover) ← 壊れてる
/srm2/login       → 200 (旧VF base login)     ← 生きてる
/srm2/CommunitiesLogin → 401 (認証レイヤー)   ← 生きてる
/srm2/s/          → 200 (LWR container)       ← 生きてる
```

**LWR の `/s/login` ビルド artifact だけが Salesforce サーバ側で破損**。メタデータは無罪。

#### 打開策の発見

`/srm2/login`（旧VF）経由なら生きている → ポータルユーザのパスワードを設定して VF login で入る方針。

1. **`EmailSenderAddress` 確認**: API で Network を見ると `snagahara+00die000000idkv@salesforce.com` に既設定 → `System.setPassword` が通る条件満たしている（前回 memory の「INSUFFICIENT_ACCESS」は Email 未設定時の話だった）
2. **`System.setPassword('005Ie000000IXAvIAO', 'Yoshida@Demo2026!')`** → ✅ 成功
3. **旧 login 画面 `/srm2/login` にアクセス、Username/Password 入力** → `Restricted IP` でログイン失敗
4. **Login History の SourceIp を確認**: `240d:1a:a51:3100:650d:f215:6880:61fc` = IPv6 アドレス
5. **Partner Community User Profile の LoginIpRange 確認**: `0.0.0.0-255.255.255.255` のみ設定 → **IPv4 のみカバー、IPv6 拒否**
6. **LoginIpRange レコードを削除**（制限なし＝全IP許可に） → ✅ ログイン成功

### 完了（2026-04-19）

- ✅ ExperienceBundle の健全性をローカル検査（破損なし確定）
- ✅ `/s/login` 503 は Salesforce サーバ側の問題と判明、迂回路発見
- ✅ ポータルユーザ吉田のパスワード設定: `Yoshida@Demo2026!`
- ✅ Partner Community User Profile の LoginIpRange 削除（IPv6 対応）
- ✅ **吉田ユーザで `/srm2/login` 経由のブラウザログイン成功**（初のポータル実機到達）

### 明日以降のテスト残

- [ ] ホーム画面の KPI/RFQリスト/調査リスト表示確認
- [ ] RFQカード クリック → `/rfq-response?rfqId=...` 遷移 → 回答フォーム動作確認（下書き保存/回答提出/辞退）
- [ ] 調査カード クリック → `/investigation-response?investigationId=...` 遷移 → 回答動作確認
- [ ] キャパシティ管理 `/capacity` で自社/協力会社別表示
- [ ] 認証一覧 `/certifications` で有効/期限間近/期限切れ色分け
- [ ] 製造拠点マップ `/sites` でピン表示
- [ ] **Sharing 視覚確認**: 他 Account（グリーンエナジーセル以外）のデータが見えないことを目視

### デモ本番時の注意事項

- **ログイン URL は `/srm2/login`**（旧VF）を使う。`/srm2/s/login` は 503 のまま。
- **`/s/login` 503 の復旧はデモ期間中は諦める**。Salesforce サポート案件レベルで、demo org では起票不可。
- **Log in as 経由は使えない**（最終的に `/s/login` に redirect される設計のため）。Username/Password ベースでログインする必要がある。

### 停止ポイント（2026-04-19 23時頃）

吉田ユーザで `/srm2/login` から初ログイン成功直後。ポータルホーム画面（`supplierPortalHome` LWC）の表示確認はまだ。翌日以降に §6「明日以降のテスト残」を順に消化する。

### 参考：認証情報

| 項目 | 値 |
|---|---|
| ログインURL | `https://trailsignup-61aa736aacb04f.my.site.com/srm2/login` |
| Username | `yoshida1776431632685@greenenergy.demo.sfdc` |
| Password | `Yoshida@Demo2026!` |
| Profile | Partner Community User (`00eIe000000VUDbIAO`) |
| User Id | `005Ie000000IXAvIAO` |
| Contact Id | `003Ie000008UAQCIA4` |
| Account Id | `001Ie00000Aq4lsIAB` (グリーンエナジーセル) |

---

## 7. 2026-04-20 完了記録

### 残タスクの完了状況

| チェック項目 | 結果 |
|---|---|
| ホーム画面(supplierPortalHome) | ✅ 動作 |
| 製造拠点(/sites) | ✅ 動作 |
| 生産キャパシティ(/capacity) | ✅ 動作 |
| 認証・資格(/certifications) | ✅ 動作 |
| RFQ 見積回答 | ✅ 動作（インライン表示に変更） |
| 調査回答 | ✅ 動作（インライン表示に変更） |

### RFQ/調査回答ページが表示されなかった問題 — 根本原因と対応

**症状**: `/srm2/s/rfq-response?rfqId=xxx` および `/srm2/s/investigation-response?investigationId=xxx` が白画面。DOM を検索してもカスタム LWC タグが存在せず。他のカスタムページ(sites/capacity/certifications)は正常描画。

**原因**: Partner Central Enhanced Template (Aura系) において、`routeType: "quote-list"` および `"case-list"` は標準 CRM オブジェクト用の OOB ハンドラに奪われ、配置したカスタム LWC が runtime で描画されない。Builder 上では LWC が配置されて見えるが、publish 後の runtime では OOB 側が描画を引き受けて白画面になる。

**試行と結果**:
1. `sf community publish` 実行 → 変化なし
2. LWC 側で `window.location.search` 直読みフォールバック追加 → 変化なし（LWC 自体が instantiate されていないため意味なし）
3. `routeType` を `rfq-response-custom` / `rfqresponse` 等の任意値に変更 → deploy validation エラー（`routeType` は予め定義済み値のホワイトリスト制）
4. **最終対応**: Home LWC 内部に `viewMode` state を追加し、RFQ/調査カードクリック時は別ページ遷移せず子 LWC をインライン表示する設計に変更

### 変更ファイル

- [supplierPortalHome.js](force-app/main/default/lwc/supplierPortalHome/supplierPortalHome.js): `viewMode` state 追加、`handleRfqClick` / `handleInvestigationClick` をインライン切替に変更
- [supplierPortalHome.html](force-app/main/default/lwc/supplierPortalHome/supplierPortalHome.html): `isRfqMode` / `isInvestigationMode` ブロックで子 LWC を `@api` 経由で描画
- [supplierPortalHome.css](force-app/main/default/lwc/supplierPortalHome/supplierPortalHome.css): `.spc-inline-detail` / `.spc-back-btn` スタイル追加

### 残置アイテム（害なし）

壊れたカスタムページ `/rfq-response` (routeType=quote-list) と `/investigation-response` (routeType=case-list) は ExperienceBundle に残したまま。ユーザがアクセスする導線は撤去済みなので実害なし。次回クリーンアップ時に ExperienceBundle から削除予定。

### 既知問題の追補（memory）

`feedback_experience_cloud_user_creation.md` item 13–15 に反映済み:
- 13: `quote-list`/`case-list` routeType は OOB ハンドラに奪われる
- 14: `routeType` はホワイトリスト制
- 15: Aura 系テンプレートでは URL クエリパラメータが LWC に届かないことがある → インライン表示で回避
