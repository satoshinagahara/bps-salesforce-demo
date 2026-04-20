"""lh360 フォーカスアカウント向けシードデータ投入スクリプト。

BPS SAE ペルソナ（大型案件追跡型）を想定し、6 注力アカウントに
大型 Opportunity / Contact / 12 週分の Activity を投入する。

【設計】
- 既存データは削除しない（CloseDate 等の日付ずらしも行わない）
- 追加する全レコードは Is_Demo_Seed__c = true でマーク
- 対象アカウントは Is_Focal_Account__c = true
- OwnerId はログインユーザ（sysadmin=SAEと見立て、注力 Account にフォーカスする想定）
- 冪等性: Opportunity.Name に prefix `[DEMO-SEED]` を付け、既存チェックで二重投入防止

【使い方】
  python lh360/scripts/seed_focal_data.py
  python lh360/scripts/seed_focal_data.py --dry-run

【関連】
  lh360/scripts/shift_demo_dates.py - 投入後に時間経過したら日付を相対シフトして鮮度復活
"""
from __future__ import annotations

import argparse
import csv
import json
import random
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

# 再現性のため乱数 seed を固定
random.seed(42)

ORG = "trailsignup.61aa736aacb04f@salesforce.com"
DEMO_PREFIX = "[DEMO-SEED]"

# 6 注力アカウント（既存アカウントを選定。AnnualRevenue/Industry 補完対象含む）
FOCAL_ACCOUNT_NAMES = [
    "アライドパワー株式会社",         # Utilities, 5.6B（既設）
    "オメガエネルギー株式会社",       # Energy, 87M（既設）
    "関東広域エネルギー公社",         # Government, revenue NULL → 補完
    "中部電設株式会社",               # Utilities, revenue NULL → 補完
    "富士精密機械",                   # Manufacturing, revenue NULL → 補完
    "東亜電子工業",                   # Electronics, revenue NULL → 補完
]

# Opp 商談 11 件（ステージ分布: Discovery 3 / Proposal 4 / Negotiation 3 / Closed Won 1）
# Amount は 50M〜500M JPY。CloseDate は「最近 or 近い将来」で鮮度感を出す。
OPP_BLUEPRINT = [
    # (account_index, name_suffix, stage, amount, close_offset_days, description)
    (0, "次世代系統安定化プラットフォーム 主要設備更新", "Proposal/Quote", 380_000_000, 45,
     "既設SCADA更新＋需給制御モジュール刷新。3年段階導入。"),
    (0, "東北エリア 変電所デジタル化 Phase1", "Negotiation", 220_000_000, 20,
     "2026年度予算承認済、Phase1は5変電所。Phase2以降も視野。"),
    (0, "AMI(スマートメータ) 拡張配置", "Discovery", 150_000_000, 90,
     "既存AMIの広域化。検討段階、コンペ 2社。"),

    (1, "洋上風力 運用監視センター構築", "Proposal/Quote", 450_000_000, 60,
     "秋田沖プロジェクト向け。監視・予測・異常検知統合。"),
    (1, "LNG基地 DCS リプレース", "Negotiation", 280_000_000, 30,
     "築20年のDCS更新。既存プラントを停止せずに切替必須。"),
    (1, "再エネ予測 AI モデル導入", "Discovery", 85_000_000, 120,
     "天候連動出力予測の高精度化。PoC 提案中。"),

    (2, "スマートシティ統合基盤 実証フェーズ2", "Proposal/Quote", 320_000_000, 50,
     "フェーズ1成功を受け、対象地区を3倍に拡大。"),
    (2, "広域防災連携 通信バックボーン", "Closed Won", 180_000_000, -15,
     "既に契約締結済。2026年5月キックオフ予定。"),

    (3, "送配電自動化 リモート制御拡張", "Proposal/Quote", 240_000_000, 40,
     "山間部区間を含む遠隔制御範囲拡大。"),

    (4, "MES 刷新 ＋ 品質トレーサビリティ統合", "Negotiation", 360_000_000, 25,
     "既設MES老朽化。品質データの一元化が最優先。"),
    (4, "予知保全 IoT センサー全工場展開", "Proposal/Quote", 120_000_000, 75,
     "本社工場での成功後、全国5工場展開。"),

    (5, "半導体実装ライン 制御系刷新", "Discovery", 95_000_000, 110,
     "ライン老朽化、次世代製品対応のため検討中。"),
]

# Contact テンプレート（各 focal account に 3〜4 名）
CONTACT_TEMPLATES = [
    {"title": "経営企画部長", "role": "Economic Buyer"},
    {"title": "情報システム部長", "role": "Technical Buyer"},
    {"title": "生産技術課長", "role": "User"},
    {"title": "購買部長", "role": "Other"},
    {"title": "DX推進室長", "role": "Champion"},
]

FIRST_NAMES = ["太郎", "花子", "健一", "由美", "信夫", "美咲", "隆", "恵子"]
LAST_NAMES_POOL = ["佐藤", "鈴木", "高橋", "田中", "伊藤", "山田", "中村", "小林", "加藤", "渡辺"]


@dataclass
class OppPlan:
    account_id: str
    account_name: str
    name: str
    stage: str
    amount: int
    close_date: date
    description: str


def sh(cmd: list[str], check: bool = True) -> str:
    """sf CLI を呼び出すヘルパ。"""
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"[sh failed] {' '.join(cmd)}", file=sys.stderr)
        print(r.stdout, file=sys.stderr)
        print(r.stderr, file=sys.stderr)
        raise RuntimeError(f"command failed: {cmd[0]}")
    return r.stdout


def soql(query: str) -> list[dict]:
    """SOQL を実行して records を返す。"""
    out = sh(["sf", "data", "query", "--query", query, "--target-org", ORG,
              "--result-format", "json"])
    data = json.loads(out)
    return data.get("result", {}).get("records", [])


def sf_create(sobject: str, fields: dict[str, Any]) -> str:
    """sf data create record で 1 件作成して Id を返す。"""
    kv = " ".join(f'{k}="{_escape(v)}"' for k, v in fields.items())
    out = sh(["sf", "data", "create", "record",
              "--sobject", sobject, "--values", kv,
              "--target-org", ORG, "--json"])
    data = json.loads(out)
    return data["result"]["id"]


def sf_update(sobject: str, record_id: str, fields: dict[str, Any]) -> None:
    kv = " ".join(f'{k}="{_escape(v)}"' for k, v in fields.items())
    sh(["sf", "data", "update", "record", "--sobject", sobject,
        "--record-id", record_id, "--values", kv,
        "--target-org", ORG, "--json"])


def sf_bulk_insert(sobject: str, rows: list[dict]) -> None:
    """CSV 経由で大量 insert。全行共通のフィールド集合を算出し、欠損はblank埋め。"""
    if not rows:
        return
    # 全行のkey unionを取る
    all_keys: list[str] = []
    seen: set[str] = set()
    for r in rows:
        for k in r.keys():
            if k not in seen:
                seen.add(k)
                all_keys.append(k)
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=all_keys, extrasaction="ignore")
        writer.writeheader()
        for r in rows:
            # 欠損keyはblank埋め（DictWriterの標準動作）
            writer.writerow(r)
        csv_path = f.name
    print(f"  bulk insert {sobject}: {len(rows)} rows (csv={csv_path})")
    try:
        r = subprocess.run(
            ["sf", "data", "import", "bulk", "--sobject", sobject,
             "--file", csv_path, "--wait", "10",
             "--line-ending", "CRLF",
             "--target-org", ORG],
            capture_output=True, text=True,
        )
        # stdoutをそのまま出す（進捗バーが最終行に結果サマリ含む）
        tail = "\n".join(r.stdout.splitlines()[-15:])
        print(tail)
        if r.returncode != 0:
            print(f"  [bulk error] exit={r.returncode}")
            print(r.stderr[:500])
            print(f"  [csv retained for debug] {csv_path}")
            return
    finally:
        # 成功時のみ削除
        if 'r' in locals() and r.returncode == 0:
            Path(csv_path).unlink(missing_ok=True)


def _escape(v: Any) -> str:
    if v is None:
        return ""
    s = str(v)
    return s.replace('"', '\\"')


def get_login_user_id() -> str:
    rec = soql(f"SELECT Id FROM User WHERE Username='{ORG}'")
    return rec[0]["Id"]


def ensure_focal_accounts(dry_run: bool = False) -> list[dict]:
    """6 focal accounts を特定し、Is_Focal / Is_Demo_Seed / 補完情報を付与。"""
    print("\n[1] Focal accounts の flag 設定")
    quoted = ", ".join(f"'{n}'" for n in FOCAL_ACCOUNT_NAMES)
    recs = soql(f"SELECT Id, Name, Industry, AnnualRevenue FROM Account WHERE Name IN ({quoted})")
    by_name = {r["Name"]: r for r in recs}
    missing = [n for n in FOCAL_ACCOUNT_NAMES if n not in by_name]
    if missing:
        raise RuntimeError(f"focal accounts not found: {missing}")

    # 補完プラン
    enrichment = {
        "関東広域エネルギー公社": {"AnnualRevenue": 3_200_000_000, "Industry": "Government"},
        "中部電設株式会社": {"AnnualRevenue": 1_800_000_000, "Industry": "Utilities"},
        "富士精密機械": {"AnnualRevenue": 2_400_000_000, "Industry": "Manufacturing"},
        "東亜電子工業": {"AnnualRevenue": 1_500_000_000, "Industry": "Electronics"},
    }

    ordered: list[dict] = []
    for name in FOCAL_ACCOUNT_NAMES:
        r = by_name[name]
        updates: dict[str, Any] = {"Is_Focal_Account__c": "true", "Is_Demo_Seed__c": "true"}
        if name in enrichment:
            if not r.get("AnnualRevenue"):
                updates["AnnualRevenue"] = enrichment[name]["AnnualRevenue"]
            if not r.get("Industry"):
                updates["Industry"] = enrichment[name]["Industry"]
        print(f"  - {name} ({r['Id']}) updates={list(updates.keys())}")
        if not dry_run:
            sf_update("Account", r["Id"], updates)
        ordered.append({"Id": r["Id"], "Name": name})
    return ordered


def seed_opportunities(accounts: list[dict], owner_id: str, today: date, dry_run: bool) -> list[str]:
    """Opp を作成。既に同名が存在したらスキップ。"""
    print("\n[2] Opportunity seed")
    existing = soql(
        f"SELECT Id, Name FROM Opportunity WHERE Name LIKE '{DEMO_PREFIX}%'"
    )
    existing_names = {r["Name"] for r in existing}
    created_ids: list[str] = []
    for (acc_idx, suffix, stage, amount, offset, desc) in OPP_BLUEPRINT:
        acc = accounts[acc_idx]
        name = f"{DEMO_PREFIX} {acc['Name']} {suffix}"
        if name in existing_names:
            print(f"  skip (exists): {name}")
            # 既存ID も取得
            rec = soql(f"SELECT Id FROM Opportunity WHERE Name='{_escape(name)}' LIMIT 1")
            if rec:
                created_ids.append(rec[0]["Id"])
            continue
        close_date = today + timedelta(days=offset)
        fields = {
            "Name": name,
            "AccountId": acc["Id"],
            "StageName": stage,
            "Amount": amount,
            "CloseDate": close_date.isoformat(),
            "OwnerId": owner_id,
            "Description": desc,
            "Is_Demo_Seed__c": "true",
        }
        print(f"  create: {name} [{stage}] {amount:,} JPY close={close_date}")
        if not dry_run:
            oid = sf_create("Opportunity", fields)
            created_ids.append(oid)
    return created_ids


LAST_NAMES_ROMAN = {
    "佐藤": "sato", "鈴木": "suzuki", "高橋": "takahashi", "田中": "tanaka",
    "伊藤": "ito", "山田": "yamada", "中村": "nakamura", "小林": "kobayashi",
    "加藤": "kato", "渡辺": "watanabe",
}


def seed_contacts(accounts: list[dict], dry_run: bool) -> dict[str, list[str]]:
    """各 focal account に 3〜4 Contacts 追加。既に Demo Contact があるアカウントはスキップ（冪等）。"""
    print("\n[3] Contact seed")
    result: dict[str, list[str]] = {}
    # 冪等: 既存 Demo Contact があれば再利用
    existing = soql(
        "SELECT Id, AccountId FROM Contact WHERE Is_Demo_Seed__c = true"
    )
    existing_by_acc: dict[str, list[str]] = {}
    for r in existing:
        existing_by_acc.setdefault(r["AccountId"], []).append(r["Id"])

    for acc in accounts:
        if acc["Id"] in existing_by_acc:
            print(f"  skip (exists): {acc['Name']} ({len(existing_by_acc[acc['Id']])} demo contacts)")
            result[acc["Id"]] = existing_by_acc[acc["Id"]]
            continue
        n = random.randint(3, 4)
        ids: list[str] = []
        templates = random.sample(CONTACT_TEMPLATES, k=n)
        for i, tmpl in enumerate(templates):
            last = random.choice(LAST_NAMES_POOL)
            first = random.choice(FIRST_NAMES)
            last_roman = LAST_NAMES_ROMAN.get(last, "demo")
            fields = {
                "AccountId": acc["Id"],
                "LastName": last,
                "FirstName": first,
                "Title": tmpl["title"],
                "Email": f"{last_roman}.{i}@{_ascii_domain(acc['Name'])}.example.jp",
                "Is_Demo_Seed__c": "true",
            }
            print(f"  create contact: {last}{first} ({tmpl['title']}) @ {acc['Name']}")
            if not dry_run:
                cid = sf_create("Contact", fields)
                ids.append(cid)
        result[acc["Id"]] = ids
    return result


def _ascii_domain(name: str) -> str:
    """日本語 account 名から ASCII っぽい domain を作る（メール生成用）。"""
    # 簡略: ランダムコード
    return "acc" + str(abs(hash(name)) % 10000)


def seed_activities(opp_ids: list[str], opp_names: list[str], acc_map: dict[str, dict],
                    contacts_by_acc: dict[str, list[str]], owner_id: str,
                    today: date, dry_run: bool) -> None:
    """各 Opp に 12 週分 + 今週の活動を生成。Task/Event 混在。"""
    print("\n[4] Activities seed (12週分 + 今週)")
    # 冪等: 既に Demo Tasks or Events が 50件以上あればスキップ
    existing_task_cnt = soql("SELECT COUNT(Id) cnt FROM Task WHERE Is_Demo_Seed__c = true")
    existing_evt_cnt = soql("SELECT COUNT(Id) cnt FROM Event WHERE Is_Demo_Seed__c = true")
    t_cnt = existing_task_cnt[0]["cnt"] if existing_task_cnt else 0
    e_cnt = existing_evt_cnt[0]["cnt"] if existing_evt_cnt else 0
    if t_cnt + e_cnt >= 50:
        print(f"  skip (exists): already {t_cnt} Tasks + {e_cnt} Events with Is_Demo_Seed__c = true")
        return

    activity_templates_past = [
        ("Task", "初回訪問議事録まとめ", "キーパーソン {contact} 氏と面談、プロジェクト背景ヒアリング。"),
        ("Task", "社内キックオフ報告", "当案件の戦略方針を営業部内で共有。"),
        ("Event", "現地ヒアリング", "現地設備視察とユーザ部門からの要件聴取。"),
        ("Task", "提案骨子ドラフト", "Proposal 初版作成。技術部レビュー依頼中。"),
        ("Event", "定例進捗ミーティング", "{contact} 氏と進捗共有、次回アクション確定。"),
        ("Task", "見積調整", "値引き原案作成、上長承認取得。"),
        ("Task", "技術質問への回答準備", "RFI 対応、ソリューション仕様書添付。"),
        ("Event", "役員向けプレゼン", "経営層への最終プレゼン実施。評価高め。"),
        ("Task", "競合情報収集", "競合他社の動向調査まとめ。"),
        ("Task", "稟議書ドラフトレビュー", "顧客側稟議書のレビュー依頼対応。"),
    ]
    activity_templates_this_week = [
        ("Task", "【今週】顧客からの追加質問対応", "価格根拠と導入体制についての追加質問に回答。"),
        ("Event", "【今週】意思決定者との面談", "{contact} 役員と直接対話。詳細詰め。"),
        ("Task", "【今週】見積改訂版送付", "スコープ調整後の改訂見積を送付。"),
        ("Task", "【今週】法務レビュー依頼", "契約書ドラフトを法務に送付。"),
        ("Event", "【今週】社内作戦会議", "技術部・営業部横断でクロージング戦略協議。"),
    ]

    tasks: list[dict] = []
    events: list[dict] = []

    for opp_id, opp_name in zip(opp_ids, opp_names):
        # Opp から Account を逆引き
        acc_id = None
        for aid, acc in acc_map.items():
            if acc["Name"] in opp_name:
                acc_id = aid
                break
        if acc_id is None:
            continue
        contact_ids = contacts_by_acc.get(acc_id, [])
        # 12週分: 週あたり 1.5 件くらい（ばらつかせる）
        for week in range(12, 0, -1):  # 過去12週前 → 1週前
            n_this_week = random.choice([1, 1, 2, 2, 3])
            for _ in range(n_this_week):
                tmpl = random.choice(activity_templates_past)
                sobject, subj, desc_tmpl = tmpl
                activity_date = today - timedelta(days=week * 7 + random.randint(0, 6))
                # 過去日に WhoId を紐付け（ランダム contact）
                who_id = random.choice(contact_ids) if contact_ids else None
                rec = {
                    "Subject": subj,
                    "WhatId": opp_id,
                    "OwnerId": owner_id,
                    "Description": desc_tmpl.format(contact="先方担当"),
                    "Is_Demo_Seed__c": "true",
                }
                if who_id:
                    rec["WhoId"] = who_id
                if sobject == "Task":
                    rec["ActivityDate"] = activity_date.isoformat()
                    rec["Status"] = "Completed"
                    rec["Priority"] = random.choice(["Normal", "High"])
                    tasks.append(rec)
                else:
                    # Event: StartDateTime/EndDateTime (UTC ISO)
                    start_dt = datetime.combine(activity_date, datetime.min.time()).replace(hour=random.randint(9, 16))
                    end_dt = start_dt + timedelta(hours=1)
                    rec["ActivityDate"] = activity_date.isoformat()
                    rec["DurationInMinutes"] = "60"
                    rec["ActivityDateTime"] = start_dt.isoformat() + ".000+0900"
                    events.append(rec)

        # 今週分 (2〜3件)
        n_current = random.choice([2, 2, 3])
        for _ in range(n_current):
            tmpl = random.choice(activity_templates_this_week)
            sobject, subj, desc_tmpl = tmpl
            activity_date = today - timedelta(days=random.randint(0, 6))
            who_id = random.choice(contact_ids) if contact_ids else None
            rec = {
                "Subject": subj,
                "WhatId": opp_id,
                "OwnerId": owner_id,
                "Description": desc_tmpl.format(contact="先方担当"),
                "Is_Demo_Seed__c": "true",
            }
            if who_id:
                rec["WhoId"] = who_id
            if sobject == "Task":
                rec["ActivityDate"] = activity_date.isoformat()
                rec["Status"] = random.choice(["In Progress", "Not Started"])
                rec["Priority"] = "High"
                tasks.append(rec)
            else:
                start_dt = datetime.combine(activity_date, datetime.min.time()).replace(hour=random.randint(9, 16))
                rec["ActivityDate"] = activity_date.isoformat()
                rec["DurationInMinutes"] = "60"
                rec["ActivityDateTime"] = start_dt.isoformat() + ".000+0900"
                events.append(rec)

    print(f"  planned: {len(tasks)} Tasks, {len(events)} Events")
    if dry_run:
        return
    sf_bulk_insert("Task", tasks)
    sf_bulk_insert("Event", events)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="何も更新せず計画だけ出す")
    args = ap.parse_args()

    today = date.today()
    print(f"=== lh360 seed_focal_data (today={today}, dry_run={args.dry_run}) ===")

    owner_id = get_login_user_id()
    print(f"OwnerId (login user): {owner_id}")

    accounts = ensure_focal_accounts(dry_run=args.dry_run)
    acc_map = {a["Id"]: a for a in accounts}

    opp_ids = seed_opportunities(accounts, owner_id, today, args.dry_run)
    opp_names_recs = soql(
        f"SELECT Id, Name, AccountId FROM Opportunity WHERE Id IN ({_in_clause(opp_ids)})"
    ) if opp_ids else []
    opp_name_by_id = {r["Id"]: r["Name"] for r in opp_names_recs}
    opp_names = [opp_name_by_id.get(i, "") for i in opp_ids]

    contacts_by_acc = seed_contacts(accounts, args.dry_run)
    seed_activities(opp_ids, opp_names, acc_map, contacts_by_acc, owner_id, today, args.dry_run)

    print("\n=== done ===")


def _in_clause(ids: list[str]) -> str:
    return ", ".join(f"'{i}'" for i in ids)


if __name__ == "__main__":
    main()
