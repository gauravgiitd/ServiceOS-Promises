# ServiceOS Promises

Local analytics app and SQL workspace for ServiceOS customer promise performance.

This folder is meant to be self-contained enough that a new Codex chat opened here can understand the promise metric, refresh the data, run the familiar SQL query, and continue building the app.

## Current App

The app is a static local web app:

- `index.html`
- `src/app.js`
- `src/styles.css`
- `data/promise_instances.json`
- `data/metadata.json`

It shows:

- All cities and their promise metrics.
- Drilldown inside a city to all agents and their promise metrics.
- Agent search and sortable agent metric columns.
- Drilldown inside an agent to an interactive promise timeline.
- Hover details for scheduled start, start trip, reached location, completion, reschedule, and cancellation markers.
- Reschedule hover details include new promise slot, new agent, same/different agent, and reschedule reason.
- Global date control in the top right:
  - Defaults to Yesterday.
  - Day mode: Yesterday, Day before, or custom date.
  - Range mode: Last 7 days, Last 14 days, or custom range.
  - The filter applies across city, agent, and timeline pages.
- URL-driven navigation:
  - Global: `#/global?date_mode=single&date_preset=yesterday&date=2026-05-16`
  - City: `#/city?date_mode=single&date_preset=yesterday&date=2026-05-16&city=Bangalore`
  - Agent: `#/agent?date_mode=single&date_preset=yesterday&date=2026-05-16&city=Bangalore&agent_id=123`
  - Browser back/forward controls navigation; the app does not use an explicit in-page back button.
- Breadcrumb navigation follows `Cities -> <City> -> <Agent>` and uses the same URL routes as browser back/forward.
- Metric cards show a daily trend on hover. Day mode shows the selected day plus the previous six days; range mode shows one point per selected date.

The timeline uses a time-of-day axis instead of one absolute multi-day axis, so one-hour promise slots remain readable even for 7-day or 14-day views.

## Run Locally

From this folder:

```bash
python3 -m http.server 5174 --bind 127.0.0.1
```

Open:

```text
http://127.0.0.1:5174/
```

## Refresh App Data

From this folder:

```bash
python3 scripts/refresh_data.py
```

The script runs:

```text
sql/promise_instances_last14.sql
```

It writes:

- `data/promise_instances.csv`
- `data/promise_instances.json`
- `data/metadata.json`

The query currently exports the last 14 calendar days including today in `Asia/Kolkata`.

## BigQuery Auth

This workspace expects the `bq` CLI to be available and authenticated. The refresh script automatically uses this service account file if present:

```text
~/.config/codex-gcp/storm-wall-codex.json
```

It sets these environment variables for the subprocess:

```text
CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE
GOOGLE_APPLICATION_CREDENTIALS
```

## Key SQL Files

### `sql/promise_instances_last14.sql`

Used by the app. It exports promise-level rows, not only aggregates. The browser app computes city and agent metrics from these rows.

Important output fields include:

- `promise_id`
- `promise_date`
- `city_name`
- `zone_name`
- `task_type_name`
- `task_id`
- `job_id`
- `agent_id`
- `agent_name`
- `scheduled_start_at_ist`
- `start_trip_at_ist`
- `slot_start_at_ist`
- `slot_end_at_ist`
- `customer_reached_at_ist`
- `completed_at_ist`
- `rescheduled_at_ist`
- `rescheduled_to_slot_start_at_ist`
- `rescheduled_to_slot_end_at_ist`
- `rescheduled_to_agent_id`
- `rescheduled_to_agent_name`
- `rescheduled_agent_change_type`
- `cancelled_at_ist`
- `promise_bucket`
- `raw_reschedule_reason`
- `has_previous_successful_overlapping_promise_blocker`
- `is_not_met_and_no_blockers`
- `serviceos_auto_recovered_at_ist`

### `sql/bangalore_promise_success_daily_trend_with_no_blockers.sql`

This is the familiar query used before the app to get Bangalore daily promise success trend. Keep this around because the user still expects Codex to run it occasionally while moving to the app.

It currently has hardcoded dates at the top:

```sql
DECLARE start_date DATE DEFAULT DATE '2026-05-03';
DECLARE end_date DATE DEFAULT DATE '2026-05-16';
```

Before running it, update those two dates or convert them to a dynamic range, depending on the ask.

## Promise Calculation Logic

The metric is calculated at promise-instance level, not final task level.

A promise instance is identified by:

```text
task_id + slot_start_at + slot_end_at
```

If a task is rescheduled, the old promise is closed and a new promise is created. The old promise is not edited. This is important because it prevents a later completion or next-day reschedule from hiding a missed commitment for the earlier slot.

Cutoff:

```text
cutoff_time = slot_start_at - 1 hour
```

Classification order:

1. Cancelled on or before cutoff: `EXCLUDED`
2. Rescheduled on or before cutoff: `EXCLUDED`
3. Cancelled after cutoff: `NOT_MET_CANCELLED_AFTER_CUTOFF`
4. Rescheduled after cutoff: `NOT_MET_RESCHEDULED_AFTER_CUTOFF`
5. Reached more than 30 minutes after slot end: `NOT_MET_REACHED_TOO_LATE`
6. No mapped arrival event in the promise window: `NOT_MET_REST_REASONS`
7. Reached more than 30 minutes before slot start: `NOT_MET_REACHED_TOO_EARLY`
8. Reached from 30 minutes before slot start up to slot start: `MET_EARLY`
9. Reached within slot: `MET`
10. Reached after slot end but within 30-minute grace: `MET_WITH_DELAY`
11. Anything else: `NOT_MET_REST_REASONS`

Success includes:

```text
MET_EARLY + MET + MET_WITH_DELAY
```

Valid promises include all success and failure buckets, excluding only `EXCLUDED`.

## Arrival State Mapping

The query maps task type to the state used as the arrival event.

Current mapping:

- Survey task types: `Reached Survey Location`
- Key delivery: `Reached Drop Location`
- Jarvis PUD drop: `Reached Service Center`
- Flatbed / underlift towing: `Reached Garage Location`
- QC / quality: `Reached Garage`
- Most pickup, PI, roadside repair: `Reached Customer Location`
- Drop and ADSC Drop: promise SLA is measured at customer location, so arrival state is forced to `Reached Customer Location`

Important nuance:

For Drop and ADSC Drop, customer promise SLA should be measured against the customer/end location, not the garage/start location. In `promise_instances_last14.sql`, these task types use `requested_end_location` for city/zone/SLA location context when available.

## Actual Transitions Only

The query avoids reusing old carried-forward states by requiring actual transitions:

- Current status/state must match the target.
- Previous status/state must be different.
- Arrival and start-trip events must be strictly after `promise_created_at`.

This fixed the earlier issue where old state values could make a new promise look like it was reached too early.

## Not Met And No Blockers

`is_not_met_and_no_blockers` is true when the promise failed for one of these buckets:

- `NOT_MET_CANCELLED_AFTER_CUTOFF`
- `NOT_MET_RESCHEDULED_AFTER_CUTOFF`
- `NOT_MET_REST_REASONS`

And the same agent, in the same city, did not have an earlier different-task promise that:

- Was scheduled before the current promise.
- Was still unresolved when the current promise was scheduled to start.
- Eventually succeeded as `MET_EARLY`, `MET`, or `MET_WITH_DELAY`.

Plain English:

```text
Not met and no blockers = late cancellation + late reschedule + unresolved/no-arrival miss,
excluding cases where the agent was already fulfilling an overlapping successful promise.
```

## Auto-Recovery Metric

Auto-recovery is inferred from `serviceos_auto_recovered_at_ist`, which comes from task version rows where:

```text
updated_by or created_by = recovery-orchestration
```

And assignee changed from previous assignee to a new assignee.

This is a useful proxy, not a full detection-signal based measure. The team was expected to add `serviceos_detection_signal` to GBQ for a more complete at-risk and recovered funnel.

## Main GBQ Tables Used

- `storm-wall-185017.Stage.karya_serviceos_db_serviceos_task_versioned_data`
- `storm-wall-185017.Stage.karya_serviceos_db_serviceos_tasks`
- `storm-wall-185017.Stage.vyavastha_serviceos_db_task_config`
- `storm-wall-185017.Stage.vyavastha_serviceos_db_master_location`
- `storm-wall-185017.Stage.vyavastha_serviceos_db_master_location_group`
- `storm-wall-185017.Stage.serviceos_upbhokta_db_serviceos_user`

## Known Constraints

- App drilldowns are fast because they use pre-generated JSON. They do not query BigQuery on every click.
- If the user wants a fresh date range outside the generated JSON window, refresh the data first or adjust `sql/promise_instances_last14.sql`.
- `sql/bangalore_promise_success_daily_trend_with_no_blockers.sql` is still Bangalore-specific and aggregate-oriented.
- Reschedule reasons come from task versioned data and should be treated as directional, not perfect ground truth.
- Current app data reflects the last successful refresh, not live BigQuery.

## Suggested Codex Workflow In A New Chat

1. Open this folder:

   ```text
   /Users/gaurav.gupta/Code/ServiceOS Promises
   ```

2. Read this README first.

3. If asked to run the app:

   ```bash
   python3 -m http.server 5174 --bind 127.0.0.1
   ```

4. If asked to refresh app data:

   ```bash
   python3 scripts/refresh_data.py
   ```

5. If asked to run the old promise success query, use:

   ```text
   sql/bangalore_promise_success_daily_trend_with_no_blockers.sql
   ```

6. If asked to change promise logic, update both:

   - `sql/promise_instances_last14.sql`
   - `sql/bangalore_promise_success_daily_trend_with_no_blockers.sql`, if the aggregate query still needs to match.
