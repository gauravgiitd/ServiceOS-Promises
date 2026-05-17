#!/usr/bin/env python3
import csv
import json
import os
import subprocess
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
SOURCE_WATERMARK_SQL = """
DECLARE start_date DATE DEFAULT DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 13 DAY);
DECLARE end_date DATE DEFAULT CURRENT_DATE('Asia/Kolkata');

WITH source_versions AS (
  SELECT
    COALESCE(tvd.update_initiated_at, tvd.created_on) AS source_event_at
  FROM `storm-wall-185017.Stage.karya_serviceos_db_serviceos_task_versioned_data` tvd
  JOIN `storm-wall-185017.Stage.karya_serviceos_db_serviceos_tasks` t
    ON t.id = tvd.task_id
  WHERE tvd.slot_start_date_time IS NOT NULL
    AND DATE(tvd.slot_start_date_time, 'Asia/Kolkata') BETWEEN start_date AND end_date
)
SELECT
  FORMAT_TIMESTAMP('%FT%T%Ez', MAX(source_event_at), 'UTC') AS latest_source_event_at_utc,
  COUNTIF(source_event_at > TIMESTAMP('{last_watermark}')) AS new_source_row_count,
  COUNT(*) AS scanned_source_row_count
FROM source_versions;
"""
DEFAULT_WATERMARK = "1970-01-01T00:00:00+00:00"
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
    configured_credential = env.get("SERVICEOS_GBQ_CREDENTIALS") or env.get("GOOGLE_APPLICATION_CREDENTIALS")
    credential_path = Path(configured_credential).expanduser() if configured_credential else Path.home() / ".config" / "codex-gcp" / "storm-wall-codex.json"
    if credential_path.exists():
        env.setdefault("CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE", str(credential_path))
        env.setdefault("GOOGLE_APPLICATION_CREDENTIALS", str(credential_path))
    return env


def run_bq_sql(sql, timeout=1800):
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
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"bq query failed with exit code {result.returncode}")
    return result.stdout


def extract_csv_text(output, header_prefix):
    lines = output.splitlines()
    header_index = next((idx for idx, line in enumerate(lines) if line.startswith(header_prefix)), None)
    if header_index is None:
        raise RuntimeError("Could not find CSV header in bq output.")
    csv_text = "\n".join(lines[header_index:]) + "\n"
    return csv_text


def run_bq():
    csv_text = extract_csv_text(run_bq_sql(SQL_PATH.read_text()), HEADER_PREFIX)
    RAW_CSV.write_text(csv_text)
    return csv_text


def read_metadata():
    if not META_PATH.exists():
        return {}
    return json.loads(META_PATH.read_text())


def source_watermark(last_watermark=None):
    watermark = last_watermark or DEFAULT_WATERMARK
    safe_watermark = watermark.replace("'", "")
    output = run_bq_sql(SOURCE_WATERMARK_SQL.format(last_watermark=safe_watermark), timeout=300)
    csv_text = extract_csv_text(output, "latest_source_event_at_utc,")
    row = next(csv.DictReader(csv_text.splitlines()), None) or {}
    return {
        "latest_source_event_at_utc": row.get("latest_source_event_at_utc") or None,
        "new_source_row_count": int(row.get("new_source_row_count") or 0),
        "scanned_source_row_count": int(row.get("scanned_source_row_count") or 0),
    }


def sync_if_needed(progress=None):
    def update(stage, message):
        if progress:
            progress(stage, message)

    DATA_DIR.mkdir(exist_ok=True)
    current_metadata = read_metadata()
    last_watermark = current_metadata.get("source_watermark", {}).get("latest_source_event_at_utc")

    update("checking", "Checking BigQuery for new task updates...")
    watermark = source_watermark(last_watermark)
    if last_watermark and watermark["new_source_row_count"] == 0:
        current_metadata["last_sync_checked_at"] = datetime.now(ZoneInfo("Asia/Kolkata")).strftime("%Y-%m-%d %H:%M:%S %Z")
        current_metadata["source_watermark"] = watermark
        META_PATH.write_text(json.dumps(current_metadata, indent=2))
        update("complete", "No new task updates found in BigQuery.")
        return {"refreshed": False, "metadata": current_metadata, "watermark": watermark}

    update("running", "New task updates found. Running the full promise query...")
    csv_text = run_bq()
    update("writing", "Writing refreshed app data...")
    metadata = write_json(csv_text, source_watermark=watermark)
    update("complete", "Refresh complete.")
    return {"refreshed": True, "metadata": metadata, "watermark": watermark}


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


def write_json(csv_text, source_watermark=None):
    records = [coerce(row) for row in csv.DictReader(csv_text.splitlines())]
    JSON_PATH.write_text(json.dumps(records, separators=(",", ":")))

    dates = sorted({row["promise_date"] for row in records if row.get("promise_date")})
    slot_starts = sorted({row["slot_start_at_ist"] for row in records if row.get("slot_start_at_ist")})
    slot_ends = sorted({row["slot_end_at_ist"] for row in records if row.get("slot_end_at_ist")})
    metadata = {
        "generated_at": datetime.now(ZoneInfo("Asia/Kolkata")).strftime("%Y-%m-%d %H:%M:%S %Z"),
        "source": str(SQL_PATH.relative_to(ROOT)),
        "record_count": len(records),
        "source_watermark": source_watermark,
        "date_range": {
            "start_date": dates[0],
            "end_date": dates[-1],
        }
        if dates
        else None,
        "task_time_range": {
            "earliest_slot_start_at_ist": slot_starts[0],
            "latest_slot_start_at_ist": slot_starts[-1],
            "latest_slot_end_at_ist": slot_ends[-1],
        }
        if slot_starts and slot_ends
        else None,
    }
    META_PATH.write_text(json.dumps(metadata, indent=2))
    return metadata


def main():
    DATA_DIR.mkdir(exist_ok=True)
    result = sync_if_needed(lambda stage, message: print(message))
    metadata = result["metadata"]
    if result["refreshed"]:
        print(f"Wrote {JSON_PATH} with {metadata['record_count']} promise instances")
        print(f"Wrote {META_PATH}")


if __name__ == "__main__":
    main()
