## LWC
- **App Builder表示名**: meta.xmlの`masterLabel`でApp Builder表示名が変わる。混乱を避けるため使わないか、設定時はユーザーに伝える
- **targets指定は配置場所ごとに必須**: `lightning__RecordPage`のみ指定したLWCはホームページのApp Builderに表示されない
- **`@wire` は `cacheable=true` 必須**: Apex wireで `@AuraEnabled(cacheable=false)` のメソッドを `@wire` すると callback が発火せず、LWCにデータが来ない(無言で黙る)。imperative呼び出しは cacheable に関係なく可能。`refreshApex` は cacheable=true wireでも正常動作する。検証日: 2026-04-24 (idpQuoteDualEntry で発覚、画面にレコード項目が全く表示されない症状)
- **複数LWC間の wire cache 共有パターン**: 同じApex method + 同じ引数で wire すると、異なるLWCでもキャッシュが共有される。1つのLWCで Apex DML 後に `refreshApex` すると、他LWCの wire も同時に最新値で再発火する。複数LWCでの状態同期を実現するシンプルな方法。Lightning Message Service よりも軽量(検証日: 2026-04-24、idpQuoteFileUploader と idpQuoteDualEntry のステータス同期で採用)
- **業務ステータスと処理状態の分離**: ピックリストに「処理中」「エラー」等の一時状態を混ぜず、業務ステータスのみに絞ると認知負荷が下がる。処理状態は派生可能なフィールド(DateTime null/not-nullや Error_Message の有無)から LWC で導出する方が保守性高い(検証日: 2026-04-24、IDP_Review_Status__c を7値→4値に簡素化)

## Metadata API / Deploy
- **OpportunityStage等のlabelはMetadata APIで変更不可**: 翻訳ワークベンチ（Translation Settings）を使う
- **ソーストラッキングなし**: `--ignore-conflicts` フラグで対処
- **FlexiPageのレコードタイプ別割当はUIが確実**: Lightning App Builder → Activation から手動割当

## Permission Set
- **FLS問題**: カスタムオブジェクト/フィールドデプロイ後、FLSが未設定だとSOQLで見えない。`BOM_Full_Access` 権限セットに追加
- **MD関係項目はFLS設定不可**: `fieldPermissions`に含めるとデプロイエラー。除外すること
- **必須項目(required=true)もFLS設定不可**: 同上
- **XML要素順序**: classAccesses → fieldPermissions → hasActivationRequired → label → objectPermissions → recordTypeVisibilities
- **Knowledge__kav RecordTypeはPermissionSetで割当必要**: RecordTypeVisibilitiesに追加しないとDML時にエラー

## Object / Field
- **Product2はMD親になれない**: BOM_Header__cのProduct__cはLookup(SetNull)で実装
- **子リレーション名はdescribeで確認必須**: 命名規則から推測せず `sf sobject describe` で確認
- **数式フィールド**: Percent型は小数返却（75%→0.75）
- **Task/EventのカスタムフィールドはActivityに定義する**: `objects/Task/fields/*.field-meta.xml` や `objects/Event/fields/*.field-meta.xml` を直接作るとデプロイエラー（"エンティティのエミュレーションまたは ID: 制限つき選択リスト項目の値が不適切: Event"）。Task/EventはActivityの派生のため、`force-app/main/default/objects/Activity/fields/MyField__c.field-meta.xml` に作成すればTask/Event両方で共有される。権限セットの `<field>` 参照も `Activity.MyField__c` で指定する（Task.MyField__c / Event.MyField__c は不可）。検証日: 2026-04-19

## Apex / API
- **ConnectApi temperatureはApexでのみ設定可能**: `additionalConfig.temperature`で指定。推奨値: 分析=0.2, メール=0.4, クイズ=0.7
- **ConnectApi.applicationName必須**: `'PromptBuilderPreview'` がないとPrompt Template呼出しが失敗
- **Knowledge__kav SOSLにはLanguage WHERE必須**: orgデフォルト`en_US`なら`AND Language = 'en_US'`を付ける
- **SOSLはDraft記事を検索しない**: SOQL or Apex内マッチングが必要
- **Prompt TemplateはデプロイだけではActivateされない**: Prompt Builder UIで手動Activate必要
- **sf data import bulk はCRLF CSVを要求**: Python `csv.DictWriter` で生成したCSVを `sf data import bulk --sobject Xxx --file xxx.csv` に渡すと、"ClientInputError : LineEnding is invalid on user data. Current LineEnding setting is LF" でbulk jobが失敗する。`--line-ending LF` を明示しても同じエラー（Bulk API 2.0側がCRLF前提の模様）。`--line-ending CRLF` を指定すれば通る。Python csv.DictWriter は `newline=""` 指定でも lineterminator 既定 `\r\n` なので実ファイルは元々CRLFであり、このフラグで整合する。関連: `lh360/scripts/seed_focal_data.py`, `lh360/scripts/shift_demo_dates.py`。検証日: 2026-04-19

## ローカルLLM / mlx-lm

- **mlx-lm server の `MLX_STRIP_TOOLS` 既定値に注意**: `/Users/satoshi/claude/gemma4-install/scripts/start_server.sh` の既定 `MLX_STRIP_TOOLS=1` は Jan等のUIが常時送信する tools パラメータを剥ぎ取る対策。Agent Loop で tool calling を使う場合は `MLX_STRIP_TOOLS=0` で再起動必須
  - 症状: tools を渡しても `finish_reason=stop` で自然言語応答（コードブロック等）が返る
  - 解決: `MLX_STRIP_TOOLS=0 MLX_MODEL=... bash start_server.sh`
- **Gemma 4 26B A4B (mlx-community/gemma-4-26b-a4b-it-4bit) の tool calling 実測 (M5 Mac)**: STRIP_TOOLS=0 で OpenAI互換 `tool_calls` 構造を完全サポート、並列 tool_calls も自発発行可。実測 ~30 tok/s（4bit量子化）。日本語プロンプト・日本語引数・SOQL生成精度良好

## Agentforce

> **注**: Agentforceの一般的な技術制約（メタデータ構造、CLI制限、アーキテクチャ指針等）は `salesforce-admin` スキルの `metadata-agentforce.md` に集約済み。以下は**このorg固有の問題・運用メモ**のみ記載。

### このorg固有の問題
- **1 Agent集約方式**: 製品・調達・品質マネジメントエージェント（BOM_Analysis_Agent）に全Topicを集約。Agentforce Employee Agentは Inactive（詳細は `agentforce-architecture-guide.md` 参照）
- **Agentforce入力のID解決**: Agent LLMはCA名（CA-0000）を渡すことがある。Name検索→ID変換のフォールバックをApex側で実装済み
- **同一セッション内のAction再実行問題**: Agent LLMが過去の出力を使い回す場合がある。Instructionsに「毎回必ず実行」と明示して対策（詳細は `agentforce-architecture-guide.md` セクション4参照）
- **分析系プロンプトは「事実のみ」スタイル**: 「提案は含めない」を明示する運用にしている

## Experience Cloud (Partner Central Enhanced)

ExperienceBundle にカスタムページを追加する際の制約（検証日: 2026-04-20, SRMポータル Wave 2）。

### routeType の制約
- **テンプレートが構造的に要求する routeType がある**: `enablement-program-link`, `enablement-program-video` 等。これらの route を完全削除するとデプロイエラー（「サイトにはルート種別 X のルートが必要です」）。消すなら最小限のスタブ route を残す
- **URL アドレス可能な routeType は限られる**: `enablement-program-*` 系は `urlPrefix` 単独では NavigationMenuItem から到達不可（recordId 必須のドリルダウン詳細ページ扱い）。「URL パスのサイトにページが見つかりません」エラーになる
- **乗っ取り先として動作確認済の routeType**: `quote-list`, `case-list`, `jointbusinessplan-list`, `voucher-list`, `mdf`。これらは独自 LWC に差し替えても URL 経由で到達可能
- **`routeType` はホワイトリスト制**: 任意値（例: `rfq-response-custom`）はデプロイ時の validation で弾かれる
- **`enablement-program-list` は pageAccess=UseParent 必須**、他の `enablement-program-*` は pageAccess を持てない

### routes / views の整合性
- **1:1 対応が必須**: route の `activeViewId` と view の `id` が一致、route の `routeType` と view の `viewType` が一致
- **孤立 view はデプロイエラー**: 「ビューに対応するルートがありません」。route 削除時は view も同時削除する

### NavigationMenuItem の運用
- **ページが site に publish されてから作成する**: `sf community publish` 未実行だと「URL パスのサイトにページが見つかりません」エラー
- **Position はステータス内で一意**: 既存 Draft/Live と衝突する場合は逆順（大→小）でシフトする
- **Publish で Draft → Live 昇格**: `sf community publish` 実行で Draft アイテムが自動的に Live にコピーされる

### Aura 系テンプレートの挙動
- **URL クエリパラメータが LWC に届かないことがある**: `window.location.search` 直読みフォールバックで回避不可（LWC 自体が instantiate されないため）。**ビュー切替パターン**（単一 LWC 内で `viewMode` state で画面遷移）で回避するのが確実

## Hosted MCP Server (External Client App 連携)

Salesforce Hosted MCP Server（`api.salesforce.com/platform/mcp/v1/...`）を外部MCPクライアント（Claude Desktop等）から利用する際の設定ポイント。

### External Client App (ECA) 側設定
- **JWTベースアクセストークンは ON 必須**: `api.salesforce.com/platform/mcp/*` エンドポイントはPlatform API Gatewayでステートレス検証するため、Opaque tokenでは認証エラー（`Authorization with the MCP server failed`, 参照ID `ofid_xxxx`）になる。**セキュリティ → 「指名ユーザーの JSON Web トークン (JWT) ベースのアクセストークンを発行」を ON**
- **PKCE 必須**: 「サポートされる認証フローに PKCE 拡張を要求」を ON
- **Web サーバーフローの秘密は OFF**: PKCEで代替するため Secret不要
- **必須 OAuth Scope**: `api`, `refresh_token, offline_access`, `mcp_api`, `sfap_api`
  - `mcp_api` が無いとMCPサーバーエンドポイントへのアクセスが拒否される
- **Callback URL (Claude Desktop)**: `https://claude.ai/api/mcp/auth_callback`
- **Flow**: 「認証コードおよびログイン情報フローを有効化」のみ ON
- **Policies**: 許可されているユーザー = `すべてのユーザーは自己承認可能`、IP緩和を設定
- **反映タイムラグ**: 設定変更後 2-10分 の反映時間あり。保存直後のエラーは時間を置いて再試行

### Claude Desktop側設定
- Custom Connector 追加時、Server URL と OAuth Client ID（= ECAのConsumer Key）を指定
- Consumer Secretは不要（PKCE使用のため）
- 失敗時は**既存接続を切断してから再試行**（キャッシュされた認証情報が残るため）

### 権限セットの罠
- `C2CMcpServicePermSet` は **Cloud Integration User ライセンス専用**（サーバー間C2C連携用）。Claude Desktop等のユーザーOAuthフローには無関係。割り当てようとするとライセンスミスマッチエラー
- ユーザー側OAuthフローでは追加の権限セット不要（`mcp_api` scopeのみで可）

## Cloud Monitoring Dashboard (BigQuery メトリクス)

Cloud Monitoring でカスタムダッシュボードを作るときの BigQuery メトリクス特有の詰まりポイント（検証日: 2026-04-23, BPS × GCP Live Operations ダッシュボード構築時）。

### metric kind と aligner の組み合わせ
- **GAUGE に `ALIGN_RATE` は適用不可**: `bigquery.googleapis.com/query/count` は GAUGE/INT64。`ALIGN_RATE` を指定すると "Field aggregation.perSeriesAligner had an invalid value of ALIGN_RATE: The aligner cannot be applied to..." エラー
- **クエリ件数を rate で可視化したい場合は `query/execution_count` を使う**: こちらは DELTA/INT64 なので `ALIGN_RATE` / `ALIGN_DELTA` が通る

### resource type の落とし穴（BQ は metric ごとに `bigquery_project` / `global` が混在）
- **`query/scanned_bytes`・`query/scanned_bytes_billed` は resource type = `global`** のみ。`bigquery_project` を指定すると "The supplied filter does not specify a valid combination of metric and monitored resource descriptors" エラー
- **`slots/allocated_for_project`・`slots/allocated_for_reservation` も resource type = `global`** のみ
- **`query/count`・`query/execution_times` は両方対応**（`bigquery_project`, `global` どちらでも OK）
- **`query/execution_count`・`query/statement_scanned_bytes` は `bigquery_project` のみ**

### 確認手順（迷ったら REST で引く）
`gcloud` には metric-descriptors list サブコマンドが無いので、REST で引くのが早い:
```bash
TOKEN=$(gcloud auth print-access-token)
curl -s "https://monitoring.googleapis.com/v3/projects/PROJECT/metricDescriptors?filter=metric.type%3Dstarts_with%28%22bigquery.googleapis.com%22%29&pageSize=100" \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r '.metricDescriptors[] | "\(.type) \(.metricKind) \(.valueType) \(.monitoredResourceTypes)"'
```

### Dashboard update 時の etag
- `gcloud monitoring dashboards update` は `etag` 必須。JSON に `etag` と `name` を埋めてから渡す
- etag は `gcloud monitoring dashboards describe <id> --format="value(etag)"` で取得
