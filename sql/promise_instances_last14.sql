DECLARE start_date DATE DEFAULT DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 13 DAY);
DECLARE end_date DATE DEFAULT CURRENT_DATE('Asia/Kolkata');

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
  task_type_search,
  task_type_name IN (CONCAT('ADSC Dr', 'op'), CONCAT('Dr', 'op')) AS use_end_location_for_sla,
  IF(
    task_type_name IN (CONCAT('ADSC Dr', 'op'), CONCAT('Dr', 'op')),
    'Reached Customer Location',
    base_arrival_state
  ) AS sla_arrival_state
FROM base;

CREATE TEMP TABLE agent_dim AS
SELECT
  id AS agent_id,
  name AS agent_name,
  role AS agent_role
FROM (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY id
      ORDER BY updated_on DESC, update_id DESC
    ) AS rn
  FROM `storm-wall-185017.Stage.serviceos_upbhokta_db_serviceos_user`
  WHERE deleted_on IS NULL
)
WHERE rn = 1;

CREATE TEMP TABLE base_task_versions AS
SELECT
  tvd.id AS task_versioned_data_id,
  tvd.task_id,
  t.job_id,
  t.master_task_config_slug,
  COALESCE(ttc.task_type_name, t.master_task_config_slug) AS task_type_name,
  COALESCE(ttc.sla_arrival_state, 'Reached Customer Location') AS sla_arrival_state,
  COALESCE(ttc.use_end_location_for_sla, FALSE) AS use_end_location_for_sla,
  COALESCE(tvd.requested_start_location, t.requested_start_location) AS requested_start_location_json,
  COALESCE(tvd.requested_end_location, t.requested_end_location) AS requested_end_location_json,
  tvd.version,
  tvd.created_on,
  COALESCE(tvd.update_initiated_at, tvd.created_on) AS event_at,
  tvd.slot_start_date_time AS slot_start_at,
  tvd.slot_end_date_time AS slot_end_at,
  tvd.scheduled_start_datetime AS scheduled_start_at,
  tvd.scheduled_end_datetime AS scheduled_end_at,
  tvd.status,
  tvd.state,
  tvd.assignee,
  tvd.reschedule_reason,
  tvd.updated_by,
  tvd.created_by
FROM `storm-wall-185017.Stage.karya_serviceos_db_serviceos_task_versioned_data` tvd
JOIN `storm-wall-185017.Stage.karya_serviceos_db_serviceos_tasks` t
  ON t.id = tvd.task_id
LEFT JOIN task_type_config ttc
  ON ttc.slug = t.master_task_config_slug;

CREATE TEMP TABLE candidate_task_versions AS
SELECT
  btv.*,
  CASE
    WHEN btv.use_end_location_for_sla
      THEN COALESCE(btv.requested_end_location_json, btv.requested_start_location_json)
    ELSE COALESCE(btv.requested_start_location_json, btv.requested_end_location_json)
  END AS promise_location_json,
  CASE
    WHEN LOWER(TRIM(COALESCE(lc_id.city_name, lc_pin.city_name))) IN ('bangalore', 'bengaluru')
      THEN 'Bangalore'
    ELSE COALESCE(NULLIF(TRIM(COALESCE(lc_id.city_name, lc_pin.city_name)), ''), 'Unknown')
  END AS city_name,
  COALESCE(
    NULLIF(TRIM(COALESCE(
      JSON_VALUE(
        CASE
          WHEN btv.use_end_location_for_sla
            THEN COALESCE(btv.requested_end_location_json, btv.requested_start_location_json)
          ELSE COALESCE(btv.requested_start_location_json, btv.requested_end_location_json)
        END,
        '$.zone'
      ),
      JSON_VALUE(
        CASE
          WHEN btv.use_end_location_for_sla
            THEN COALESCE(btv.requested_end_location_json, btv.requested_start_location_json)
          ELSE COALESCE(btv.requested_start_location_json, btv.requested_end_location_json)
        END,
        '$.location.zone'
      ),
      lc_id.zone_name,
      lc_pin.zone_name
    )), ''),
    'Unknown'
  ) AS zone_name
FROM base_task_versions btv
LEFT JOIN location_by_id lc_id
  ON lc_id.location_id = SAFE_CAST(JSON_VALUE(
    CASE
      WHEN btv.use_end_location_for_sla
        THEN COALESCE(btv.requested_end_location_json, btv.requested_start_location_json)
      ELSE COALESCE(btv.requested_start_location_json, btv.requested_end_location_json)
    END,
    '$.location_id'
  ) AS INT64)
LEFT JOIN location_by_pincode lc_pin
  ON lc_pin.pincode = NULLIF(TRIM(JSON_VALUE(
    CASE
      WHEN btv.use_end_location_for_sla
        THEN COALESCE(btv.requested_end_location_json, btv.requested_start_location_json)
      ELSE COALESCE(btv.requested_start_location_json, btv.requested_end_location_json)
    END,
    '$.pincode'
  )), '')
QUALIFY COUNTIF(
  slot_start_at IS NOT NULL
  AND slot_end_at IS NOT NULL
  AND DATE(slot_start_at, 'Asia/Kolkata') BETWEEN start_date AND end_date
) OVER (PARTITION BY task_id) > 0;

CREATE TEMP TABLE version_rows AS
SELECT
  ctv.task_versioned_data_id,
  ctv.task_id,
  ctv.job_id,
  ctv.task_type_name,
  ctv.sla_arrival_state,
  ctv.city_name,
  ctv.zone_name,
  ctv.assignee,
  ctv.version,
  ctv.created_on,
  ctv.event_at,
  ctv.slot_start_at,
  ctv.slot_end_at,
  COALESCE(ctv.scheduled_start_at, ctv.slot_start_at) AS scheduled_start_at,
  COALESCE(ctv.scheduled_end_at, ctv.slot_end_at) AS scheduled_end_at,
  LAG(ctv.slot_start_at) OVER (
    PARTITION BY ctv.task_id
    ORDER BY ctv.version, ctv.created_on, ctv.task_versioned_data_id
  ) AS prev_slot_start_at,
  LAG(ctv.slot_end_at) OVER (
    PARTITION BY ctv.task_id
    ORDER BY ctv.version, ctv.created_on, ctv.task_versioned_data_id
  ) AS prev_slot_end_at
FROM candidate_task_versions ctv
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
  scheduled_start_at,
  scheduled_end_at,
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
  ) AS closed_by_reschedule_at,
  LEAD(event_sequence) OVER (
    PARTITION BY task_id
    ORDER BY promise_created_at, event_sequence
  ) AS closed_by_reschedule_event_sequence
FROM slot_events se;

CREATE TEMP TABLE task_events AS
SELECT
  task_id,
  event_at,
  status,
  prev_status,
  state_norm,
  prev_state_norm,
  assignee,
  reschedule_reason
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
    assignee,
    reschedule_reason
  FROM candidate_task_versions
);

CREATE TEMP TABLE task_completion AS
SELECT
  task_id,
  MIN(IF(status IN ('done', 'completed') AND COALESCE(prev_status, '') NOT IN ('done', 'completed'), event_at, NULL)) AS completed_at
FROM task_events
GROUP BY task_id;

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
  pc.scheduled_start_at,
  pc.scheduled_end_at,
  pc.event_sequence,
  pc.closed_by_reschedule_at,
  pc.closed_by_reschedule_event_sequence,
  COALESCE(
    ARRAY_AGG(te.assignee IGNORE NULLS ORDER BY te.event_at DESC LIMIT 1)[SAFE_OFFSET(0)],
    pc.assignee_at_promise
  ) AS agent_id,
  MIN(IF(te.status = 'cancelled' AND COALESCE(te.prev_status, '') <> 'cancelled', te.event_at, NULL)) AS cancelled_at,
  MIN(IF(te.state_norm = 'start trip' AND COALESCE(te.prev_state_norm, '') <> 'start trip' AND te.event_at > pc.promise_created_at, te.event_at, NULL)) AS start_trip_at,
  MIN(
    IF(
      te.state_norm = LOWER(TRIM(pc.sla_arrival_state))
      AND COALESCE(te.prev_state_norm, '') <> LOWER(TRIM(pc.sla_arrival_state))
      AND te.event_at > pc.promise_created_at,
      te.event_at,
      NULL
    )
  ) AS customer_reached_at,
  MIN(saru.serviceos_auto_recovered_at) AS serviceos_auto_recovered_at,
  ARRAY_AGG(rte.reschedule_reason IGNORE NULLS ORDER BY rte.event_at LIMIT 1)[SAFE_OFFSET(0)] AS raw_reschedule_reason
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
LEFT JOIN task_events rte
  ON rte.task_id = pc.task_id
 AND pc.closed_by_reschedule_at IS NOT NULL
 AND rte.event_at = pc.closed_by_reschedule_at
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
  pc.scheduled_start_at,
  pc.scheduled_end_at,
  pc.event_sequence,
  pc.closed_by_reschedule_at,
  pc.closed_by_reschedule_event_sequence,
  pc.assignee_at_promise;

CREATE TEMP TABLE classified AS
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
FROM promise_facts pf;

CREATE TEMP TABLE classified_with_blockers AS
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
FROM classified c;

SELECT
  CONCAT(
    CAST(c.task_id AS STRING),
    '|',
    FORMAT_TIMESTAMP('%F %T%Ez', c.promise_created_at, 'Asia/Kolkata'),
    '|',
    CAST(c.event_sequence AS STRING)
  ) AS promise_id,
  CAST(c.promise_date AS STRING) AS promise_date,
  c.city_name,
  c.zone_name,
  c.task_type_name,
  c.sla_arrival_state,
  CAST(c.task_id AS STRING) AS task_id,
  CAST(c.job_id AS STRING) AS job_id,
  CAST(c.agent_id AS STRING) AS agent_id,
  COALESCE(agent_dim.agent_name, CAST(c.agent_id AS STRING), 'Unknown agent') AS agent_name,
  FORMAT_TIMESTAMP('%F %T%Ez', c.promise_created_at, 'Asia/Kolkata') AS promise_created_at_ist,
  FORMAT_TIMESTAMP('%F %T%Ez', c.scheduled_start_at, 'Asia/Kolkata') AS scheduled_start_at_ist,
  FORMAT_TIMESTAMP('%F %T%Ez', c.start_trip_at, 'Asia/Kolkata') AS start_trip_at_ist,
  FORMAT_TIMESTAMP('%F %T%Ez', c.slot_start_at, 'Asia/Kolkata') AS slot_start_at_ist,
  FORMAT_TIMESTAMP('%F %T%Ez', c.slot_end_at, 'Asia/Kolkata') AS slot_end_at_ist,
  FORMAT_TIMESTAMP('%F %T%Ez', c.customer_reached_at, 'Asia/Kolkata') AS customer_reached_at_ist,
  FORMAT_TIMESTAMP('%F %T%Ez', task_completion.completed_at, 'Asia/Kolkata') AS completed_at_ist,
  task_completion.completed_at IS NOT NULL AS was_completed,
  FORMAT_TIMESTAMP('%F %T%Ez', c.closed_by_reschedule_at, 'Asia/Kolkata') AS rescheduled_at_ist,
  FORMAT_TIMESTAMP('%F %T%Ez', next_promise.slot_start_at, 'Asia/Kolkata') AS rescheduled_to_slot_start_at_ist,
  FORMAT_TIMESTAMP('%F %T%Ez', next_promise.slot_end_at, 'Asia/Kolkata') AS rescheduled_to_slot_end_at_ist,
  CAST(next_promise.agent_id AS STRING) AS rescheduled_to_agent_id,
  COALESCE(next_agent_dim.agent_name, CAST(next_promise.agent_id AS STRING)) AS rescheduled_to_agent_name,
  CASE
    WHEN c.closed_by_reschedule_at IS NULL THEN 'NO_RESCHEDULE'
    WHEN next_promise.agent_id IS NULL THEN 'UNKNOWN_NEXT_AGENT'
    WHEN next_promise.agent_id = c.agent_id THEN 'SAME_AGENT'
    ELSE 'DIFFERENT_AGENT'
  END AS rescheduled_agent_change_type,
  FORMAT_TIMESTAMP('%F %T%Ez', c.cancelled_at, 'Asia/Kolkata') AS cancelled_at_ist,
  c.promise_bucket,
  c.raw_reschedule_reason,
  c.reached_too_early_minutes,
  c.reached_too_late_minutes,
  c.has_previous_successful_overlapping_promise_blocker,
  c.promise_bucket IN (
    'NOT_MET_CANCELLED_AFTER_CUTOFF',
    'NOT_MET_RESCHEDULED_AFTER_CUTOFF',
    'NOT_MET_REST_REASONS'
  )
  AND NOT c.has_previous_successful_overlapping_promise_blocker AS is_not_met_and_no_blockers,
  FORMAT_TIMESTAMP('%F %T%Ez', c.serviceos_auto_recovered_at, 'Asia/Kolkata') AS serviceos_auto_recovered_at_ist
FROM classified_with_blockers c
LEFT JOIN task_completion
  ON task_completion.task_id = c.task_id
LEFT JOIN agent_dim
  ON agent_dim.agent_id = c.agent_id
LEFT JOIN classified_with_blockers next_promise
  ON next_promise.task_id = c.task_id
 AND next_promise.promise_created_at = c.closed_by_reschedule_at
 AND next_promise.event_sequence = c.closed_by_reschedule_event_sequence
LEFT JOIN agent_dim next_agent_dim
  ON next_agent_dim.agent_id = next_promise.agent_id
WHERE c.promise_date BETWEEN start_date AND end_date
ORDER BY
  c.city_name,
  c.agent_id,
  c.slot_start_at,
  c.scheduled_start_at,
  c.task_id,
  c.promise_created_at;

