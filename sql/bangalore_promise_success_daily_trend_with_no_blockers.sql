DECLARE start_date DATE DEFAULT DATE '2026-05-03';
DECLARE end_date DATE DEFAULT DATE '2026-05-16';

CREATE TEMP TABLE location_by_id AS
SELECT
  ml.id AS location_id,
  CAST(ml.pincode AS STRING) AS pincode,
  CASE
    WHEN UPPER(zone_group.type) = 'CITY' THEN zone_group.name
    WHEN UPPER(city_group.type) = 'CITY' THEN city_group.name
    ELSE NULL
  END AS city_name,
  CASE
    WHEN UPPER(zone_group.type) = 'ZONE' THEN zone_group.name
    ELSE NULL
  END AS zone_name
FROM `storm-wall-185017.Stage.vyavastha_serviceos_db_master_location` ml
JOIN `storm-wall-185017.Stage.vyavastha_serviceos_db_master_location_group` zone_group
  ON zone_group.id = ml.location_group_id
LEFT JOIN `storm-wall-185017.Stage.vyavastha_serviceos_db_master_location_group` city_group
  ON city_group.id = zone_group.parent_group_id
WHERE ml.deleted_on IS NULL
  AND zone_group.deleted_on IS NULL
  AND (city_group.deleted_on IS NULL OR city_group.id IS NULL);

CREATE TEMP TABLE location_by_pincode AS
SELECT
  pincode,
  ARRAY_AGG(city_name IGNORE NULLS ORDER BY city_name LIMIT 1)[SAFE_OFFSET(0)] AS city_name,
  ARRAY_AGG(zone_name IGNORE NULLS ORDER BY zone_name LIMIT 1)[SAFE_OFFSET(0)] AS zone_name
FROM location_by_id
WHERE pincode IS NOT NULL
GROUP BY pincode;

CREATE TEMP TABLE task_type_config AS
WITH task_type_raw AS (
  SELECT
    slug,
    COALESCE(NULLIF(label, ''), NULLIF(name, ''), slug) AS task_type_name,
    LOWER(CONCAT(COALESCE(label, ''), ' ', COALESCE(name, ''), ' ', slug)) AS task_type_search
  FROM `storm-wall-185017.Stage.vyavastha_serviceos_db_task_config`
  WHERE deleted_on IS NULL
),
base AS (
  SELECT
    *,
    CASE
      WHEN REGEXP_CONTAINS(task_type_search, r'survey')
        THEN 'Reached Survey Location'
      WHEN REGEXP_CONTAINS(task_type_search, r'key.*deliver|key_delivery')
        THEN CONCAT('Reached Dr', 'op Location')
      WHEN REGEXP_CONTAINS(task_type_search, CONCAT(r'jarvis_pud_', 'dr', 'op'))
        THEN 'Reached Service Center'
      WHEN REGEXP_CONTAINS(task_type_search, r'flatbed_towing|underlift_towing')
        THEN 'Reached Garage Location'
      WHEN REGEXP_CONTAINS(task_type_search, CONCAT('dr', 'op'))
        THEN 'Reached Garage'
      WHEN REGEXP_CONTAINS(task_type_search, r'qc|quality')
        THEN 'Reached Garage'
      ELSE 'Reached Customer Location'
    END AS base_arrival_state
  FROM task_type_raw
)
SELECT
  slug,
  task_type_name,
  IF(
    task_type_name IN (CONCAT('ADSC Dr', 'op'), CONCAT('Dr', 'op')),
    'Reached Customer Location',
    base_arrival_state
  ) AS sla_arrival_state
FROM base;

CREATE TEMP TABLE candidate_task_versions AS
SELECT
  tvd.id AS task_versioned_data_id,
  tvd.task_id,
  t.job_id,
  t.master_task_config_slug,
  COALESCE(tvd.requested_start_location, t.requested_start_location) AS requested_location_json,
  CASE
    WHEN LOWER(TRIM(COALESCE(lc_id.city_name, lc_pin.city_name))) IN ('bangalore', 'bengaluru')
      THEN 'Bangalore'
    ELSE NULLIF(TRIM(COALESCE(lc_id.city_name, lc_pin.city_name)), '')
  END AS city_name,
  NULLIF(TRIM(COALESCE(
    JSON_VALUE(COALESCE(tvd.requested_start_location, t.requested_start_location), '$.zone'),
    JSON_VALUE(COALESCE(tvd.requested_start_location, t.requested_start_location), '$.location.zone'),
    lc_id.zone_name,
    lc_pin.zone_name
  )), '') AS zone_name,
  tvd.version,
  tvd.created_on,
  COALESCE(tvd.update_initiated_at, tvd.created_on) AS event_at,
  tvd.slot_start_date_time AS slot_start_at,
  tvd.slot_end_date_time AS slot_end_at,
  tvd.status,
  tvd.state,
  tvd.assignee,
  tvd.updated_by,
  tvd.created_by
FROM `storm-wall-185017.Stage.karya_serviceos_db_serviceos_task_versioned_data` tvd
JOIN `storm-wall-185017.Stage.karya_serviceos_db_serviceos_tasks` t
  ON t.id = tvd.task_id
LEFT JOIN location_by_id lc_id
  ON lc_id.location_id = SAFE_CAST(JSON_VALUE(COALESCE(tvd.requested_start_location, t.requested_start_location), '$.location_id') AS INT64)
LEFT JOIN location_by_pincode lc_pin
  ON lc_pin.pincode = NULLIF(TRIM(JSON_VALUE(COALESCE(tvd.requested_start_location, t.requested_start_location), '$.pincode')), '')
QUALIFY COUNTIF(
  tvd.slot_start_date_time IS NOT NULL
  AND tvd.slot_end_date_time IS NOT NULL
  AND DATE(tvd.slot_start_date_time, 'Asia/Kolkata') BETWEEN start_date AND end_date
  AND LOWER(TRIM(COALESCE(lc_id.city_name, lc_pin.city_name))) IN ('bangalore', 'bengaluru')
) OVER (PARTITION BY tvd.task_id) > 0;

CREATE TEMP TABLE version_rows AS
SELECT
  ctv.task_versioned_data_id,
  ctv.task_id,
  ctv.job_id,
  COALESCE(ttc.task_type_name, ctv.master_task_config_slug) AS task_type_name,
  COALESCE(ttc.sla_arrival_state, 'Reached Customer Location') AS sla_arrival_state,
  ctv.city_name,
  ctv.zone_name,
  ctv.assignee,
  ctv.version,
  ctv.created_on,
  ctv.event_at,
  ctv.slot_start_at,
  ctv.slot_end_at,
  LAG(ctv.slot_start_at) OVER (
    PARTITION BY ctv.task_id
    ORDER BY ctv.version, ctv.created_on, ctv.task_versioned_data_id
  ) AS prev_slot_start_at,
  LAG(ctv.slot_end_at) OVER (
    PARTITION BY ctv.task_id
    ORDER BY ctv.version, ctv.created_on, ctv.task_versioned_data_id
  ) AS prev_slot_end_at
FROM candidate_task_versions ctv
LEFT JOIN task_type_config ttc
  ON ttc.slug = ctv.master_task_config_slug
WHERE ctv.slot_start_at IS NOT NULL
  AND ctv.slot_end_at IS NOT NULL;

CREATE TEMP TABLE slot_events AS
SELECT
  task_id,
  job_id,
  task_type_name,
  sla_arrival_state,
  city_name,
  zone_name,
  assignee AS assignee_at_promise,
  event_at AS promise_created_at,
  slot_start_at,
  slot_end_at,
  version AS event_sequence
FROM version_rows
WHERE prev_slot_start_at IS NULL
   OR prev_slot_end_at IS NULL
   OR slot_start_at IS DISTINCT FROM prev_slot_start_at
   OR slot_end_at IS DISTINCT FROM prev_slot_end_at;

CREATE TEMP TABLE promise_chain AS
SELECT
  se.*,
  LEAD(promise_created_at) OVER (
    PARTITION BY task_id
    ORDER BY promise_created_at, event_sequence
  ) AS closed_by_reschedule_at
FROM slot_events se;

CREATE TEMP TABLE task_events AS
SELECT
  task_id,
  event_at,
  status,
  prev_status,
  state_norm,
  prev_state_norm,
  assignee
FROM (
  SELECT
    task_id,
    event_at,
    LOWER(TRIM(status)) AS status,
    LAG(LOWER(TRIM(status))) OVER (
      PARTITION BY task_id
      ORDER BY version, created_on, task_versioned_data_id
    ) AS prev_status,
    LOWER(TRIM(state)) AS state_norm,
    LAG(LOWER(TRIM(state))) OVER (
      PARTITION BY task_id
      ORDER BY version, created_on, task_versioned_data_id
    ) AS prev_state_norm,
    assignee
  FROM candidate_task_versions
);

CREATE TEMP TABLE serviceos_auto_recovery_updates AS
SELECT
  task_id,
  event_at AS serviceos_auto_recovered_at,
  prev_assignee AS old_assignee,
  assignee AS new_assignee
FROM (
  SELECT
    task_id,
    event_at,
    assignee,
    LAG(assignee) OVER (
      PARTITION BY task_id
      ORDER BY version, created_on, task_versioned_data_id
    ) AS prev_assignee,
    LOWER(TRIM(COALESCE(updated_by, created_by))) AS updater
  FROM candidate_task_versions
)
WHERE updater = 'recovery-orchestration'
  AND prev_assignee IS NOT NULL
  AND assignee IS NOT NULL
  AND assignee IS DISTINCT FROM prev_assignee;

CREATE TEMP TABLE promise_facts AS
SELECT
  pc.task_id,
  pc.job_id,
  pc.task_type_name,
  pc.sla_arrival_state,
  pc.city_name,
  pc.zone_name,
  pc.promise_created_at,
  pc.slot_start_at,
  pc.slot_end_at,
  pc.event_sequence,
  pc.closed_by_reschedule_at,
  COALESCE(
    ARRAY_AGG(te.assignee IGNORE NULLS ORDER BY te.event_at DESC LIMIT 1)[SAFE_OFFSET(0)],
    pc.assignee_at_promise
  ) AS agent_id,
  MIN(
    IF(
      te.status = 'cancelled'
      AND COALESCE(te.prev_status, '') <> 'cancelled',
      te.event_at,
      NULL
    )
  ) AS cancelled_at,
  MIN(
    IF(
      te.state_norm = LOWER(TRIM(pc.sla_arrival_state))
      AND COALESCE(te.prev_state_norm, '') <> LOWER(TRIM(pc.sla_arrival_state))
      AND te.event_at > pc.promise_created_at,
      te.event_at,
      NULL
    )
  ) AS customer_reached_at,
  MIN(saru.serviceos_auto_recovered_at) AS serviceos_auto_recovered_at
FROM promise_chain pc
LEFT JOIN task_events te
  ON te.task_id = pc.task_id
 AND te.event_at >= pc.promise_created_at
 AND (
      pc.closed_by_reschedule_at IS NULL
      OR te.event_at < pc.closed_by_reschedule_at
 )
LEFT JOIN serviceos_auto_recovery_updates saru
  ON saru.task_id = pc.task_id
 AND saru.serviceos_auto_recovered_at >= pc.promise_created_at
 AND (
      pc.closed_by_reschedule_at IS NULL
      OR saru.serviceos_auto_recovered_at < pc.closed_by_reschedule_at
 )
GROUP BY
  pc.task_id,
  pc.job_id,
  pc.task_type_name,
  pc.sla_arrival_state,
  pc.city_name,
  pc.zone_name,
  pc.promise_created_at,
  pc.slot_start_at,
  pc.slot_end_at,
  pc.event_sequence,
  pc.closed_by_reschedule_at,
  pc.assignee_at_promise;

WITH classified AS (
  SELECT
    pf.*,
    DATE(pf.slot_start_at, 'Asia/Kolkata') AS promise_date,
    CASE
      WHEN pf.customer_reached_at < TIMESTAMP_SUB(pf.slot_start_at, INTERVAL 30 MINUTE)
        THEN TIMESTAMP_DIFF(TIMESTAMP_SUB(pf.slot_start_at, INTERVAL 30 MINUTE), pf.customer_reached_at, MINUTE)
      ELSE NULL
    END AS reached_too_early_minutes,
    CASE
      WHEN pf.customer_reached_at > TIMESTAMP_ADD(pf.slot_end_at, INTERVAL 30 MINUTE)
        THEN TIMESTAMP_DIFF(pf.customer_reached_at, TIMESTAMP_ADD(pf.slot_end_at, INTERVAL 30 MINUTE), MINUTE)
      ELSE NULL
    END AS reached_too_late_minutes,
    CASE
      WHEN pf.cancelled_at IS NOT NULL
       AND pf.cancelled_at <= TIMESTAMP_SUB(pf.slot_start_at, INTERVAL 1 HOUR)
        THEN 'EXCLUDED'
      WHEN pf.closed_by_reschedule_at IS NOT NULL
       AND pf.closed_by_reschedule_at <= TIMESTAMP_SUB(pf.slot_start_at, INTERVAL 1 HOUR)
        THEN 'EXCLUDED'
      WHEN pf.cancelled_at IS NOT NULL
       AND pf.cancelled_at > TIMESTAMP_SUB(pf.slot_start_at, INTERVAL 1 HOUR)
        THEN 'NOT_MET_CANCELLED_AFTER_CUTOFF'
      WHEN pf.closed_by_reschedule_at IS NOT NULL
       AND pf.closed_by_reschedule_at > TIMESTAMP_SUB(pf.slot_start_at, INTERVAL 1 HOUR)
        THEN 'NOT_MET_RESCHEDULED_AFTER_CUTOFF'
      WHEN pf.customer_reached_at > TIMESTAMP_ADD(pf.slot_end_at, INTERVAL 30 MINUTE)
        THEN 'NOT_MET_REACHED_TOO_LATE'
      WHEN pf.customer_reached_at IS NULL
        THEN 'NOT_MET_REST_REASONS'
      WHEN pf.customer_reached_at < TIMESTAMP_SUB(pf.slot_start_at, INTERVAL 30 MINUTE)
        THEN 'NOT_MET_REACHED_TOO_EARLY'
      WHEN pf.customer_reached_at >= TIMESTAMP_SUB(pf.slot_start_at, INTERVAL 30 MINUTE)
       AND pf.customer_reached_at < pf.slot_start_at
        THEN 'MET_EARLY'
      WHEN pf.customer_reached_at >= pf.slot_start_at
       AND pf.customer_reached_at <= pf.slot_end_at
        THEN 'MET'
      WHEN pf.customer_reached_at > pf.slot_end_at
       AND pf.customer_reached_at <= TIMESTAMP_ADD(pf.slot_end_at, INTERVAL 30 MINUTE)
        THEN 'MET_WITH_DELAY'
      ELSE 'NOT_MET_REST_REASONS'
    END AS promise_bucket
  FROM promise_facts pf
),

classified_with_blockers AS (
  SELECT
    c.*,
    EXISTS (
      SELECT 1
      FROM classified prev
      WHERE prev.agent_id = c.agent_id
        AND prev.city_name = c.city_name
        AND prev.task_id IS DISTINCT FROM c.task_id
        AND prev.slot_start_at < c.slot_start_at
        AND prev.customer_reached_at > c.slot_start_at
        AND prev.promise_bucket IN ('MET_EARLY', 'MET', 'MET_WITH_DELAY')
    ) AS has_previous_successful_overlapping_promise_blocker
  FROM classified c
),

daily_task_totals AS (
  SELECT
    promise_date,
    city_name,
    COUNT(DISTINCT task_id) AS total_tasks
  FROM classified
  WHERE promise_date BETWEEN start_date AND end_date
    AND city_name = 'Bangalore'
  GROUP BY
    promise_date,
    city_name
)

SELECT
  CAST(c.promise_date AS STRING) AS promise_date,
  c.city_name,
  dtt.total_tasks,
  COUNT(*) AS total_promises,
  COUNTIF(c.serviceos_auto_recovered_at IS NOT NULL) AS serviceos_auto_recovered_promise_count,
  COUNTIF(
    c.serviceos_auto_recovered_at IS NOT NULL
    AND c.promise_bucket = 'MET_EARLY'
  ) AS serviceos_auto_recovered_met_early_count,
  COUNTIF(
    c.serviceos_auto_recovered_at IS NOT NULL
    AND c.promise_bucket = 'MET'
  ) AS serviceos_auto_recovered_met_count,
  COUNTIF(
    c.serviceos_auto_recovered_at IS NOT NULL
    AND c.promise_bucket = 'MET_WITH_DELAY'
  ) AS serviceos_auto_recovered_delayed_count,
  COUNTIF(
    c.serviceos_auto_recovered_at IS NOT NULL
    AND c.promise_bucket IN ('MET_EARLY', 'MET', 'MET_WITH_DELAY')
  ) AS serviceos_auto_recovered_success_count,
  COUNTIF(c.promise_bucket = 'MET_EARLY') AS met_early_count,
  COUNTIF(c.promise_bucket = 'MET') AS met_count,
  COUNTIF(c.promise_bucket = 'MET_WITH_DELAY') AS delayed_count,
  COUNTIF(c.promise_bucket = 'NOT_MET_REACHED_TOO_EARLY') AS not_met_reached_too_early_count,
  COUNTIF(c.promise_bucket = 'NOT_MET_CANCELLED_AFTER_CUTOFF') AS not_met_cancelled_after_cutoff_count,
  COUNTIF(c.promise_bucket = 'NOT_MET_RESCHEDULED_AFTER_CUTOFF') AS not_met_rescheduled_after_cutoff_count,
  COUNTIF(c.promise_bucket = 'NOT_MET_REACHED_TOO_LATE') AS not_met_reached_too_late_count,
  COUNTIF(c.promise_bucket = 'NOT_MET_REST_REASONS') AS not_met_rest_reasons_count,
  COUNTIF(
    c.promise_bucket IN (
      'NOT_MET_CANCELLED_AFTER_CUTOFF',
      'NOT_MET_RESCHEDULED_AFTER_CUTOFF',
      'NOT_MET_REST_REASONS'
    )
    AND NOT c.has_previous_successful_overlapping_promise_blocker
  ) AS not_met_and_no_blockers_count,
  COUNTIF(c.promise_bucket = 'EXCLUDED') AS excluded_count,
  ROUND(AVG(IF(c.promise_bucket = 'NOT_MET_REACHED_TOO_EARLY', c.reached_too_early_minutes, NULL)), 2)
    AS avg_reached_too_early_minutes,
  APPROX_QUANTILES(
    IF(c.promise_bucket = 'NOT_MET_REACHED_TOO_EARLY', c.reached_too_early_minutes, NULL),
    100 IGNORE NULLS
  )[SAFE_OFFSET(50)] AS p50_reached_too_early_minutes,
  ROUND(AVG(IF(c.promise_bucket = 'NOT_MET_REACHED_TOO_LATE', c.reached_too_late_minutes, NULL)), 2)
    AS avg_reached_too_late_minutes,
  APPROX_QUANTILES(
    IF(c.promise_bucket = 'NOT_MET_REACHED_TOO_LATE', c.reached_too_late_minutes, NULL),
    100 IGNORE NULLS
  )[SAFE_OFFSET(50)] AS p50_reached_too_late_minutes,
  COUNTIF(c.promise_bucket IN (
    'MET_EARLY',
    'MET',
    'MET_WITH_DELAY',
    'NOT_MET_REACHED_TOO_EARLY',
    'NOT_MET_CANCELLED_AFTER_CUTOFF',
    'NOT_MET_RESCHEDULED_AFTER_CUTOFF',
    'NOT_MET_REACHED_TOO_LATE',
    'NOT_MET_REST_REASONS'
  )) AS valid_promises,
  ROUND(SAFE_DIVIDE(
    100.0 * COUNTIF(c.promise_bucket IN ('MET_EARLY', 'MET', 'MET_WITH_DELAY')),
    COUNTIF(c.promise_bucket IN (
      'MET_EARLY',
      'MET',
      'MET_WITH_DELAY',
      'NOT_MET_REACHED_TOO_EARLY',
      'NOT_MET_CANCELLED_AFTER_CUTOFF',
      'NOT_MET_RESCHEDULED_AFTER_CUTOFF',
      'NOT_MET_REACHED_TOO_LATE',
      'NOT_MET_REST_REASONS'
    ))
  ), 2) AS success_pct,
  ROUND(SAFE_DIVIDE(
    100.0 * COUNTIF(c.promise_bucket = 'MET_WITH_DELAY'),
    COUNTIF(c.promise_bucket IN (
      'MET_EARLY',
      'MET',
      'MET_WITH_DELAY',
      'NOT_MET_REACHED_TOO_EARLY',
      'NOT_MET_CANCELLED_AFTER_CUTOFF',
      'NOT_MET_RESCHEDULED_AFTER_CUTOFF',
      'NOT_MET_REACHED_TOO_LATE',
      'NOT_MET_REST_REASONS'
    ))
  ), 2) AS delayed_pct,
  ROUND(SAFE_DIVIDE(
    100.0 * COUNTIF(c.promise_bucket IN (
      'NOT_MET_REACHED_TOO_EARLY',
      'NOT_MET_CANCELLED_AFTER_CUTOFF',
      'NOT_MET_RESCHEDULED_AFTER_CUTOFF',
      'NOT_MET_REACHED_TOO_LATE',
      'NOT_MET_REST_REASONS'
    )),
    COUNTIF(c.promise_bucket IN (
      'MET_EARLY',
      'MET',
      'MET_WITH_DELAY',
      'NOT_MET_REACHED_TOO_EARLY',
      'NOT_MET_CANCELLED_AFTER_CUTOFF',
      'NOT_MET_RESCHEDULED_AFTER_CUTOFF',
      'NOT_MET_REACHED_TOO_LATE',
      'NOT_MET_REST_REASONS'
    ))
  ), 2) AS failure_pct
FROM classified_with_blockers c
LEFT JOIN daily_task_totals dtt
  ON dtt.promise_date = c.promise_date
 AND dtt.city_name = c.city_name
WHERE c.promise_date BETWEEN start_date AND end_date
  AND c.city_name = 'Bangalore'
GROUP BY
  c.promise_date,
  c.city_name,
  dtt.total_tasks
ORDER BY
  c.promise_date,
  c.city_name;
