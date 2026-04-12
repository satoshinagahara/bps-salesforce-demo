"""
SF書き戻しテスト: sf CLIのアクセストークンを使ってDesignSuggestion__cを作成。
"""
import json
import os
import subprocess
import sys
from pathlib import Path

os.environ.setdefault("GCP_PROJECT", "ageless-lamp-251200")
os.environ.setdefault("VERTEX_LOCATION", "us-central1")
os.environ.setdefault("VERTEX_MODEL", "gemini-2.5-flash")
os.environ.setdefault("GCS_BUCKET", "bps-design-assets")

sf_display = subprocess.run(
    ["sf", "org", "display", "--target-org", "trailsignup.61aa736aacb04f@salesforce.com", "--json"],
    capture_output=True, text=True
)
sf_info = json.loads(sf_display.stdout)["result"]
os.environ["SF_ACCESS_TOKEN"] = sf_info["accessToken"]
os.environ["SF_INSTANCE_URL"] = sf_info["instanceUrl"]
print(f"SF instance: {sf_info['instanceUrl']}")
print(f"SF token: {sf_info['accessToken'][:20]}...")

sys.path.insert(0, str(Path(__file__).parent))
from main import _call_gemini, _write_to_salesforce  # noqa: E402


def main() -> None:
    with open(Path(__file__).parent / "test_request.json", encoding="utf-8") as f:
        req = json.load(f)

    print("\n=== Step 1: Calling Gemini ===")
    parsed = _call_gemini(req)
    print(json.dumps(parsed, ensure_ascii=False, indent=2))

    result = {
        "targetProduct": parsed.get("targetProduct", ""),
        "targetComponent": parsed.get("targetComponent", ""),
        "suggestionText": parsed.get("suggestionText", ""),
        "referenceSpec": parsed.get("referenceSpec", ""),
        "referenceDiagram": parsed.get("referenceDiagram", ""),
        "priority": parsed.get("priority", "中"),
        "processedBy": f"Vertex AI {os.environ['VERTEX_MODEL']}",
    }

    print("\n=== Step 2: Writing to Salesforce ===")
    sf_id = _write_to_salesforce(result, req["needsCardId"], "test_local_001")
    if sf_id:
        print(f"SUCCESS! DesignSuggestion__c created: {sf_id}")
        print(f"URL: {os.environ['SF_INSTANCE_URL']}/{sf_id}")
    else:
        print("FAILED: writeback returned None")


if __name__ == "__main__":
    main()
