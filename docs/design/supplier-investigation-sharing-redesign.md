# Supplier Investigation 共有モデル再設計

## 目的

`Supplier_Investigation__c`（サプライヤー調査）の可視性制御を「親 Corrective_Action 経由（ControlledByParent）」から「SI 自身の Supplier__c で直接制御」に変更する。

## 背景: なぜ変更が必要か

### 旧設計（変更前）

| 要素 | 設定 |
|---|---|
| `Supplier_Investigation__c` OWD | `ControlledByParent` |
| 親オブジェクト | `Corrective_Action__c` (Master-Detail) |
| Sharing Set 適用先 | `Corrective_Action__c.Supplier__c → User.Account` |

→ ポータルユーザに見える SI は「親CAの Supplier がそのユーザのAccountと一致する」ものに限定される。

### 想定外だったシナリオ: クロス会社の8D

実業務では **1つの是正処置 (CA) が複数サプライヤーを巻き込む** ケースが日常的に発生する：

- 不具合の原因が**複数の調達部品**にまたがる（例: モジュール内の抵抗とコンデンサ両方が温度耐性不足）
- 同一部品を**本命サプライヤーと代替サプライヤー**の両方から購入しており、両社に同時調査依頼を出す必要がある

このケースでは、1つのCAに対し **異なる Supplier 宛のSIが複数ぶら下がる**のが正しい状態。
しかし旧設計では CA.Supplier が1社しか指せず、**SI.Supplier ≠ CA.Supplier となるSIはポータルから見えなくなる**。

### 顕在化した症状

「グリーンエナジーセル」宛の SI が3件存在するが、ポータル上では1件しか見えない問題。

| SI | SI.Supplier | 親CA | CA.Supplier | 旧設計での可視性 |
|---|---|---|---|---|
| SI-0000 | グリーンエナジーセル | CA-0000 | グリーンエナジーセル | ✅ |
| SI-0005 | グリーンエナジーセル | CA-0002 | 東亜電子工業 | ❌ |
| SI-0006 | グリーンエナジーセル | CA-0003 | 日本マテリアルズ | ❌ |

## 新設計

### 変更内容

| 対象 | 変更前 | 変更後 |
|---|---|---|
| `Supplier_Investigation__c.sharingModel` | `ControlledByParent` | `Private` |
| `Supplier_Investigation__c.externalSharingModel` | (未設定 = ControlledByParent 継承) | `Private` |
| `Supplier_Investigation__c.Corrective_Action__c` | `MasterDetail` | `Lookup` (`deleteConstraint=SetNull`) |
| Sharing Set `Supplier_Portal_Access` | CA/Cert/Site の3マッピング | 上記 + **SI 直接マッピング** を追加 |

新規 accessMapping:
```xml
<accessMappings>
    <accessLevel>Edit</accessLevel>
    <object>Supplier_Investigation__c</object>
    <objectField>Supplier__c</objectField>
    <userField>Account</userField>
</accessMappings>
```

### 新設計での挙動

- SI は **自身の `Supplier__c` がポータルユーザの Account と一致する場合のみ可視**。
- 親CAが他社向けでも、SI 自身が「自社宛」なら見える → クロス会社8Dシナリオに対応。
- 親CAは引き続き `Corrective_Action__c` Lookup でリンク（既存データのリンクは保持）。

### 業務的影響

| ケース | 旧設計 | 新設計 |
|---|---|---|
| 親CA = SI.Supplier 一致 | 見える | 見える |
| 親CA != SI.Supplier (クロス会社8D) | 見えない | **見える** |
| 親CAなしのSI（孤立） | 作成不可（MD必須） | 作成可能（運用で抑止） |
| 親CA削除時のSI挙動 | カスケード削除 | SI残存、Corrective_Action__c=null |

## 影響範囲調査結果

| 観点 | 結果 |
|---|---|
| ロールアップサマリ | なし（CA 上に SI からの集計フィールド0件） |
| Validation Rule | なし |
| Trigger | なし |
| Flow | なし |
| Reports | reports ディレクトリ自体が存在せず |
| Apex のサブクエリ `FROM Supplier_Investigations__r` | 関係名維持で動作継続（CaseReportGenerator, CorrectiveActionProgressController） |
| FlexiPage の関連リスト | 同上、関係名維持で動作継続 |
| 権限セット `Supplier_Portal_Access` | SI に Read+Edit 既存、変更不要 |
| LWC | クエリは `Supplier__c` で絞っているため挙動変わらず（ただし可視レコード件数が増える＝意図通り） |

## 運用上の前提・注意

- **親CA削除はデモでは行わない**前提のため、`SetNull` カスケードによるSI孤立は実害なし。本番運用でも8Dの誤作成→削除は稀。
- **親CAなしSIの作成防止**は当面行わない。必要になればValidation Rule `ISBLANK(Corrective_Action__c)` で抑止可能。
- MD→Lookup は **不可逆変更**（Salesforce 制約）。本番なら Sandbox で先行検証推奨。デモ環境では直接適用。

## 関連メタデータ

- [Supplier_Investigation__c.object-meta.xml](../../force-app/main/default/objects/Supplier_Investigation__c/Supplier_Investigation__c.object-meta.xml)
- [Corrective_Action__c.field-meta.xml](../../force-app/main/default/objects/Supplier_Investigation__c/fields/Corrective_Action__c.field-meta.xml)
- [Supplier_Portal_Access.sharingSet-meta.xml](../../force-app/main/default/sharingSets/Supplier_Portal_Access.sharingSet-meta.xml)

## 適用日

2026-04-24
