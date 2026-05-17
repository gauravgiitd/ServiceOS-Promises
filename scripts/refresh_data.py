#!/usr/bin/env python3
import csv
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


ROOT = Path(__file__).resolve().parents[1]
SQL_PATH = ROOT / "sql" / "promise_instances_last14.sql"
DATA_DIR = ROOT / "data"
RAW_CSV = DATA_DIR / "promise_instances.csv"
JSON_PATH = DATA_DIR / "promise_instances.json"
META_PATH = DATA_DIR / "metadata.json"
HEADER_PREFIX = "promise_id,"
BOOL_FIELDS = {
    "was_completed",
    "has_previous_successful_overlapping_promise_blocker",
    "is_not_met_and_no_blockers",
}
NUMBER_FIELDS = {
    "reached_too_early_minutes",
    "reached_too_late_minutes",
}


def prepare_env():
    env = os.environ.copy()
    credential_path = Path.home() / ".config" / "codex-gcp" / "storm-wall-codex.json"
    if credential_path.exists():
        env.setdefault("CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", str(credential_path))
        env.setdefault("GOOGLE_APPLICATION_CREDENTIALS", str(credential_path))
    return env


def run_bq():
    sql = SQL_PATH.read_text()
    command = [
        "bq",
        "--quiet",
        "query",
        "--use_legacy_sql=false",
        "--format=csv",
        "--max_rows=10000000",
    ]
    result = subprocess.run(
        command,
        input=sql,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=prepare_env(),
        cwd=str(ROOT),
        timeout=1800,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)

    lines = result.stdout.splitlines()
    header_index = next((idx for idx, line in enumerate(lines) if line.startswith(HEADER_PREFIX)), None)
    if header_index is None:
        raise RuntimeError("Could not find CSV header in bq output.")
    csv_text = "\n".join(lines[header_index:]) + "\n"
    RAW_CSV.write_text(csv_text)
    return csv_text


def coerce(row):
    clean = {}
    for key, value in row.items():
        if value == "":
            clean[key] = None
        elif key in BOOL_FIELDS:
            clean[key] = value.lower() == "true"
        elif key in NUMBER_FIELDS:
            clean[key] = float(value) if "." in value else int(value)
        else:
            clean[key] = value
    return clean


def write_json(csv_text):
    records = [coerce(row) for row in csv.DictReader(csv_text.splitlines())]
    JSON_PATH.write_text(json.dumps(records, separators=(",", ":")))

    dates = sorted({row["promise_date"] for row in records if row.get("promise_date")})
    metadata = {
        "generated_at": datetime.now(ZoneInfo("Asia/Kolkata")).strftime("%Y-%m-%d %H:%M:%S %Z"),
        "source": str(SQL_PATH.relative_to(ROOT)),
        "record_count": len(records),
        "date_range": {
            "start_date": dates[0],
            "end_date": dates[-1],
        }
        if dates
        else None,
    }
    META_PATH.write_text(json.dumps(metadata, indent=2))
    return metadata


def main():
    DATA_DIR.mkdir(exist_ok=True)
    print(f"Running {SQL_PATH}")
    csv_text = run_bq()
    metadata = write_json(csv_text)
    print(f"Wrote {JSON_PATH} with {metadata['record_count']} promise instances")
    print(f"Wrote {META_PATH}")


if __name__ == "__main__":
    main()

