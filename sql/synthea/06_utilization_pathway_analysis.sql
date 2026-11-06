-- ============================================================
-- a06_utilization_pathway_analysis_v2.sql
--
-- PURPOSE
-- -------
-- Evaluate where a home iron-status diagnostic could fit
-- into the care pathway for the synthetic target cohort.
--
-- This file focuses on utilization and workflow rather than synthetic
-- claim dollars. It asks:
--
--   UNMET NEED
--   1. Do target patients have repeated healthcare contact around
--      relevant diagnoses?
--   2. Does utilization remain substantial after diagnosis?
--   3. Are CBC / red-cell measurements present in the workflow?
--
--   ADOPTION
--   4. In which encounter settings do target-condition encounters occur?
--   5. Which patient segments already interact with hematology testing
--      or iron-treatment workflows?
--   6. Where could an iron-status diagnostic plausibly fit into an
--      existing provider workflow?
--
--   ECONOMIC HYPOTHESIS
--   7. Does substantial post-diagnosis utilization remain, creating a
--      hypothesis that earlier identification could affect downstream
--      utilization or cost?
--
-- IMPORTANT FINDING FROM DISCOVERY
-- --------------------------------
-- This Synthea export contains common CBC/red-cell observations:
--   718-7    Hemoglobin
--   4544-3   Hematocrit, automated
--   20570-8  Hematocrit
--   787-2    MCV
--   785-6    MCH
--   786-4    MCHC
--
-- A broad and then a targeted search found NO ferritin, serum iron,
-- transferrin, TIBC, or iron-saturation observations.
--
-- Therefore:
--   - CBC / hematology measurements are treated as workflow signals.
--   - Ferritin absence is documented as a DATASET LIMITATION.
--   - Ferritin absence is NOT interpreted as evidence of a real-world
--     testing gap.
--   - NHANES will later be used for real laboratory-defined unmet need.
--   - MEPS will later be used for real utilization and economic burden.
--
-- IMPORTANT LIMITATIONS
-- ---------------------
--   1. Synthea is synthetic data. Results demonstrate an analytic
--      workflow, not real-world prevalence, utilization, access,
--      reimbursement, or economic burden.
--   2. Anemia diagnosis is not specific to iron deficiency.
--   3. CBC/red-cell measurements do not directly measure iron stores.
--   4. Observation VALUE is VARCHAR. TRY_CAST is used for profiling
--      only; no clinical thresholds are applied here.
--   5. Approximately 30k source observations have no ENCOUNTER ID.
--      Patient-level observation analyses therefore use observation
--      DATE directly so those records are not unnecessarily discarded.
--   6. Procedure discovery identified blood typing, blood smear,
--      occult-blood screening, and transfusion. These are not treated
--      as primary adoption signals in downstream marts.
--   7. Synthetic costs are intentionally excluded from business
--      conclusions in this file.
--
-- PREREQUISITES
-- -------------
--   a03_define_target_cohort.sql
--   a04_provider_organization_opportunity.sql
--
-- MAIN OUTPUTS
-- ------------
-- analytics.synthea_target_segment_index_date
-- analytics.synthea_target_hematology_observation_events
-- analytics.synthea_target_iron_medication_events
-- analytics.synthea_target_encounter_workflow_signals
-- analytics.synthea_target_segment_encounter_pathway
--
-- mart.segment_patient_pathway_summary
-- mart.utilization_pathway_by_segment
-- mart.target_condition_encounter_setting
-- mart.workflow_signal_by_segment
--
-- ============================================================


-- ============================================================
-- BLOCK 1 — ENVIRONMENT CHECK
--
-- PURPOSE:
-- Confirm the active DuckDB environment and ensure output schemas
-- exist before creating new analytical objects.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS mart;

SELECT
    current_database() AS database_name,
    current_schema() AS active_schema,
    version() AS duckdb_version;


-- ============================================================
-- BLOCK 2 — SOURCE TABLE PROFILE
--
-- PURPOSE:
-- Confirm source-table size, patient coverage, encounter coverage,
-- and missing encounter IDs.
--
-- GRAIN:
--   procedures   = one recorded procedure event
--   observations = one recorded clinical/laboratory observation
--   medications  = one recorded medication record
--
-- WHY THIS MATTERS:
-- One encounter can have many observations, procedures, and
-- medications. Directly joining raw event tables would multiply rows.
-- ============================================================

SELECT
    'procedures' AS source_table,
    COUNT(*) AS row_count,
    COUNT(DISTINCT PATIENT) AS unique_patients,
    COUNT(DISTINCT ENCOUNTER) AS unique_encounters,
    COUNT_IF(PATIENT IS NULL) AS missing_patient_ids,
    COUNT_IF(ENCOUNTER IS NULL) AS missing_encounter_ids
FROM synthea.procedures

UNION ALL

SELECT
    'observations',
    COUNT(*),
    COUNT(DISTINCT PATIENT),
    COUNT(DISTINCT ENCOUNTER),
    COUNT_IF(PATIENT IS NULL),
    COUNT_IF(ENCOUNTER IS NULL)
FROM synthea.observations

UNION ALL

SELECT
    'medications',
    COUNT(*),
    COUNT(DISTINCT PATIENT),
    COUNT(DISTINCT ENCOUNTER),
    COUNT_IF(PATIENT IS NULL),
    COUNT_IF(ENCOUNTER IS NULL)
FROM synthea.medications;


-- ============================================================
-- BLOCK 3 — ENCOUNTER LINKAGE VALIDATION
--
-- PURPOSE:
-- Confirm that non-null encounter IDs in procedures, observations,
-- and medications link to valid encounters for the same patient.
--
-- EXPECTED:
--   unmatched_encounter_ids = 0
--   patient_encounter_mismatches = 0
--
-- Note:
-- Observation records with ENCOUNTER = NULL are not errors. They
-- simply cannot be assigned to a specific encounter.
-- ============================================================

SELECT
    'procedures' AS source_table,
    COUNT(*) AS source_rows,

    COUNT_IF(
        x.ENCOUNTER IS NOT NULL
        AND e."Id" IS NULL
    ) AS unmatched_encounter_ids,

    COUNT_IF(
        e."Id" IS NOT NULL
        AND x.PATIENT <> e.PATIENT
    ) AS patient_encounter_mismatches

FROM synthea.procedures AS x

LEFT JOIN synthea.encounters AS e
    ON x.ENCOUNTER = e."Id"

UNION ALL

SELECT
    'observations',
    COUNT(*),

    COUNT_IF(
        x.ENCOUNTER IS NOT NULL
        AND e."Id" IS NULL
    ),

    COUNT_IF(
        e."Id" IS NOT NULL
        AND x.PATIENT <> e.PATIENT
    )

FROM synthea.observations AS x

LEFT JOIN synthea.encounters AS e
    ON x.ENCOUNTER = e."Id"

UNION ALL

SELECT
    'medications',
    COUNT(*),

    COUNT_IF(
        x.ENCOUNTER IS NOT NULL
        AND e."Id" IS NULL
    ),

    COUNT_IF(
        e."Id" IS NOT NULL
        AND x.PATIENT <> e.PATIENT
    )

FROM synthea.medications AS x

LEFT JOIN synthea.encounters AS e
    ON x.ENCOUNTER = e."Id";


-- ============================================================
-- BLOCK 4 — CONFIRM CBC / HEMATOLOGY OBSERVATIONS
--
-- PURPOSE:
-- Profile the validated CBC/red-cell observation codes discovered
-- in this export.
--
-- These are used downstream as EXISTING HEMATOLOGY WORKFLOW signals.
-- They are not treated as direct measures of iron stores.
--
-- IMPORTANT:
-- Code-based logic avoids false positives previously caused by text
-- matching, such as HbA1c, stool hemoglobin, or urine hemoglobin.
-- ============================================================

SELECT
    CODE AS observation_code,
    DESCRIPTION AS observation_description,
    UNITS AS observation_units,
    TYPE AS observation_type,

    COUNT(*) AS observation_records,
    COUNT(DISTINCT PATIENT) AS unique_patients,
    COUNT(DISTINCT ENCOUNTER) AS unique_linked_encounters,

    COUNT_IF(ENCOUNTER IS NULL)
        AS observations_without_encounter_id,

    COUNT_IF(
        TRY_CAST(VALUE AS DOUBLE) IS NOT NULL
    ) AS numeric_value_records

FROM synthea.observations

WHERE CODE IN (
    '718-7',    -- Hemoglobin
    '4544-3',   -- Hematocrit, automated
    '20570-8',  -- Hematocrit
    '787-2',    -- MCV
    '785-6',    -- MCH
    '786-4'     -- MCHC
)

GROUP BY
    CODE,
    DESCRIPTION,
    UNITS,
    TYPE

ORDER BY
    unique_patients DESC,
    observation_records DESC;


-- ============================================================
-- BLOCK 5 — DOCUMENT FERRITIN / IRON-STUDY AVAILABILITY
--
-- PURPOSE:
-- Reconfirm whether direct iron-store / iron-study observations exist.
--
-- EXPECTED FOR THIS EXPORT:
--   zero rows
--
-- BUSINESS INTERPRETATION:
-- Zero rows are treated as a limitation of this synthetic export.
-- They are NOT evidence that real patients are not receiving ferritin
-- or iron-study testing.
-- ============================================================

SELECT
    CODE,
    DESCRIPTION,
    UNITS,
    TYPE,
    COUNT(*) AS observation_records,
    COUNT(DISTINCT PATIENT) AS unique_patients

FROM synthea.observations

WHERE REGEXP_MATCHES(
    LOWER(COALESCE(DESCRIPTION, '')),
    'ferritin|transferrin|iron binding|total iron binding|tibc|serum iron|iron saturation|transferrin saturation|(^|[^a-z])iron([^a-z]|$)'
)

GROUP BY
    CODE,
    DESCRIPTION,
    UNITS,
    TYPE

ORDER BY
    unique_patients DESC,
    observation_records DESC;


-- ============================================================
-- BLOCK 6 — PROFILE IRON-RELATED MEDICATIONS
--
-- PURPOSE:
-- Identify whether synthetic patients receive iron replacement.
--
-- DISCOVERY RESULT:
-- Ferrous sulfate 325 mg was present in the source data.
--
-- BUSINESS USE:
-- Iron treatment can be used as a supporting treatment/workflow
-- signal, but does not prove diagnosis, adherence, or treatment need.
-- ============================================================

SELECT
    CODE AS medication_code,
    DESCRIPTION AS medication_description,

    COUNT(*) AS medication_records,
    COUNT(DISTINCT PATIENT) AS unique_patients,
    COUNT(DISTINCT ENCOUNTER) AS unique_encounters,

    MIN(START) AS earliest_start,
    MAX(START) AS latest_start

FROM synthea.medications

WHERE REGEXP_MATCHES(
    LOWER(COALESCE(DESCRIPTION, '')),
    'ferrous|ferric|ferumoxytol|iron dextran|iron sucrose|(^|[^a-z])iron([^a-z]|$)'
)

GROUP BY
    CODE,
    DESCRIPTION

ORDER BY
    unique_patients DESC,
    medication_records DESC;


-- ============================================================
-- BLOCK 7 — CREATE SEGMENT-SPECIFIC INDEX DATES
--
-- PURPOSE:
-- Establish the first recorded diagnosis date separately for each
-- patient's clinical risk segment.
--
-- GRAIN:
--   one row per patient + risk_segment
--
-- WHY SEGMENT-SPECIFIC INDEX DATES:
-- Patients may belong to multiple clinical segments. For example, a
-- patient may have pregnancy-related history before anemia. Anchoring
-- the anemia analysis to the pregnancy date would distort pre/post
-- anemia utilization. Each segment therefore receives its own index.
-- ============================================================

CREATE OR REPLACE TABLE analytics.synthea_target_segment_index_date AS

SELECT
    c.PATIENT AS patient_id,
    m.risk_segment,
    m.evidence_category,

    MIN(CAST(c.START AS DATE))
        AS first_segment_condition_date,

    COUNT(*) AS mapped_condition_records,

    COUNT(DISTINCT c.ENCOUNTER)
        AS mapped_condition_encounters

FROM synthea.conditions AS c

INNER JOIN reference.synthea_target_condition_map AS m
    ON c.CODE = m.condition_code

GROUP BY
    c.PATIENT,
    m.risk_segment,
    m.evidence_category;


-- ============================================================
-- BLOCK 8 — VALIDATE SEGMENT INDEX DATES
--
-- PURPOSE:
-- Confirm one row per patient-segment combination and reconcile the
-- number of segment memberships with the previously observed target
-- cohort overlap.
--
-- EXPECTED:
--   duplicate_patient_segment_rows = 0
--   unique_patients = 563
--   patient_segment_memberships ≈ 726
-- ============================================================

SELECT
    COUNT(*) AS patient_segment_memberships,

    COUNT(
        DISTINCT patient_id || '|' || risk_segment
    ) AS unique_patient_segment_combinations,

    COUNT(*)
    -
    COUNT(
        DISTINCT patient_id || '|' || risk_segment
    ) AS duplicate_patient_segment_rows,

    COUNT(DISTINCT patient_id)
        AS unique_target_patients,

    MIN(first_segment_condition_date)
        AS earliest_segment_index_date,

    MAX(first_segment_condition_date)
        AS latest_segment_index_date

FROM analytics.synthea_target_segment_index_date;


-- ============================================================
-- BLOCK 9 — CREATE TARGET CBC / HEMATOLOGY OBSERVATION EVENTS
--
-- PURPOSE:
-- Isolate validated CBC/red-cell observations for target patients.
--
-- GRAIN:
--   one row per matching observation record
--
-- IMPORTANT DESIGN CHOICE:
-- Records are retained even when ENCOUNTER is NULL. Observation DATE
-- allows patient-level pre/post analysis without discarding valid
-- measurements that lack encounter linkage.
-- ============================================================

CREATE OR REPLACE TABLE analytics.synthea_target_hematology_observation_events AS

SELECT
    o.DATE AS observation_datetime,
    CAST(o.DATE AS DATE) AS observation_date,

    o.PATIENT AS patient_id,
    o.ENCOUNTER AS encounter_id,

    o.CODE AS observation_code,
    o.DESCRIPTION AS observation_description,

    o.VALUE AS observation_value,
    TRY_CAST(o.VALUE AS DOUBLE)
        AS numeric_value,

    o.UNITS AS observation_units,
    o.TYPE AS observation_type,

    CASE
        WHEN o.CODE = '718-7'
            THEN 'Hemoglobin'

        WHEN o.CODE IN ('4544-3', '20570-8')
            THEN 'Hematocrit'

        WHEN o.CODE = '787-2'
            THEN 'MCV'

        WHEN o.CODE = '785-6'
            THEN 'MCH'

        WHEN o.CODE = '786-4'
            THEN 'MCHC'

        ELSE 'Other CBC / red-cell measure'
    END AS hematology_observation_category

FROM synthea.observations AS o

INNER JOIN analytics.synthea_patient_risk_flags AS rf
    ON o.PATIENT = rf.patient_id
   AND rf.risk_flag_count > 0

WHERE o.CODE IN (
    '718-7',
    '4544-3',
    '20570-8',
    '787-2',
    '785-6',
    '786-4'
);


-- ============================================================
-- BLOCK 10 — VALIDATE TARGET CBC / HEMATOLOGY EVENTS
--
-- PURPOSE:
-- Quantify which CBC/red-cell measurements occur in the target cohort
-- and how many cannot be tied to a specific encounter.
--
-- BUSINESS USE:
-- This table represents EXISTING hematology workflow, not iron-status
-- confirmation.
-- ============================================================

SELECT
    hematology_observation_category,

    COUNT(*) AS observation_records,
    COUNT(DISTINCT patient_id)
        AS unique_target_patients,

    COUNT(DISTINCT encounter_id)
        AS unique_linked_encounters,

    COUNT_IF(encounter_id IS NULL)
        AS records_without_encounter_id,

    COUNT_IF(numeric_value IS NOT NULL)
        AS numeric_observation_records

FROM analytics.synthea_target_hematology_observation_events

GROUP BY hematology_observation_category

ORDER BY
    unique_target_patients DESC,
    observation_records DESC;


-- ============================================================
-- BLOCK 11 — CREATE TARGET IRON-MEDICATION EVENTS
--
-- PURPOSE:
-- Isolate iron-related medication records for target patients.
--
-- GRAIN:
--   one row per matching medication record
--
-- COST FIELDS:
-- Retained only as source/QA fields. They are not used for adoption
-- economic conclusions.
-- ============================================================

CREATE OR REPLACE TABLE analytics.synthea_target_iron_medication_events AS

SELECT
    m.START AS medication_start_datetime,
    m.STOP AS medication_stop_datetime,
    CAST(m.START AS DATE)
        AS medication_start_date,

    m.PATIENT AS patient_id,
    m.ENCOUNTER AS encounter_id,
    m.PAYER AS payer_id,

    m.CODE AS medication_code,
    m.DESCRIPTION AS medication_description,

    m.DISPENSES AS dispenses,

    m.BASE_COST AS synthetic_base_cost_qa,
    m.PAYER_COVERAGE AS synthetic_payer_coverage_qa,
    m.TOTALCOST AS synthetic_total_cost_qa,

    m.REASONCODE AS reason_code,
    m.REASONDESCRIPTION AS reason_description

FROM synthea.medications AS m

INNER JOIN analytics.synthea_patient_risk_flags AS rf
    ON m.PATIENT = rf.patient_id
   AND rf.risk_flag_count > 0

WHERE REGEXP_MATCHES(
    LOWER(COALESCE(m.DESCRIPTION, '')),
    'ferrous|ferric|ferumoxytol|iron dextran|iron sucrose|(^|[^a-z])iron([^a-z]|$)'
);


-- ============================================================
-- BLOCK 12 — VALIDATE TARGET IRON-MEDICATION EVENTS
--
-- PURPOSE:
-- Determine how many target patients have a recorded iron-treatment
-- signal and which medication descriptions appear.
-- ============================================================

SELECT
    medication_description,

    COUNT(*) AS medication_records,
    COUNT(DISTINCT patient_id)
        AS unique_target_patients,

    COUNT(DISTINCT encounter_id)
        AS unique_encounters,

    SUM(COALESCE(dispenses, 0))
        AS total_recorded_dispenses

FROM analytics.synthea_target_iron_medication_events

GROUP BY medication_description

ORDER BY
    unique_target_patients DESC,
    medication_records DESC;


-- ============================================================
-- BLOCK 13 — CREATE ENCOUNTER-LEVEL WORKFLOW SIGNAL MART
--
-- PURPOSE:
-- Aggregate observations and medications to encounter grain BEFORE
-- joining them to the target encounter mart.
--
-- GRAIN:
--   one row per target-patient encounter
--
-- WHY PRE-AGGREGATION IS CRITICAL:
-- If one encounter has 5 observations and 3 medications, joining the
-- raw event rows could create 15 rows. Pre-aggregation prevents that
-- row multiplication.
--
-- PROCEDURES:
-- Total procedure count is retained for context, but the broad
-- "blood-related procedure" flag from the first draft was removed
-- because discovery returned workflows not specific to routine
-- iron-status testing.
-- ============================================================

CREATE OR REPLACE TABLE analytics.synthea_target_encounter_workflow_signals AS

WITH hematology_by_encounter AS (

    SELECT
        encounter_id,

        COUNT(*) AS cbc_hematology_observation_records,

        1 AS cbc_hematology_observation_flag

    FROM analytics.synthea_target_hematology_observation_events

    WHERE encounter_id IS NOT NULL

    GROUP BY encounter_id
),

procedure_by_encounter AS (

    SELECT
        ENCOUNTER AS encounter_id,

        COUNT(*) AS total_procedure_records

    FROM synthea.procedures

    WHERE ENCOUNTER IS NOT NULL

    GROUP BY ENCOUNTER
),

medication_by_encounter AS (

    SELECT
        ENCOUNTER AS encounter_id,

        COUNT(*) AS total_medication_records

    FROM synthea.medications

    WHERE ENCOUNTER IS NOT NULL

    GROUP BY ENCOUNTER
),

iron_medication_by_encounter AS (

    SELECT
        encounter_id,

        COUNT(*) AS iron_related_medication_records,

        1 AS iron_related_medication_flag

    FROM analytics.synthea_target_iron_medication_events

    WHERE encounter_id IS NOT NULL

    GROUP BY encounter_id
)

SELECT
    e.encounter_id,
    e.patient_id,

    e.service_date,
    e.service_month,
    e.encounter_class,

    e.organization_id,
    e.organization_name,

    e.provider_id,
    e.provider_name,
    e.provider_specialty,

    e.payer_id,

    e.target_condition_encounter_flag,

    e.anemia_diagnosis_flag,
    e.pregnancy_related_flag,
    e.kidney_renal_risk_flag,
    e.heart_failure_flag,
    e.risk_flag_count,

    COALESCE(
        h.cbc_hematology_observation_records,
        0
    ) AS cbc_hematology_observation_records,

    COALESCE(
        h.cbc_hematology_observation_flag,
        0
    ) AS cbc_hematology_observation_flag,

    COALESCE(
        p.total_procedure_records,
        0
    ) AS total_procedure_records,

    COALESCE(
        m.total_medication_records,
        0
    ) AS total_medication_records,

    COALESCE(
        im.iron_related_medication_records,
        0
    ) AS iron_related_medication_records,

    COALESCE(
        im.iron_related_medication_flag,
        0
    ) AS iron_related_medication_flag

FROM analytics.synthea_target_encounter_mart AS e

LEFT JOIN hematology_by_encounter AS h
    ON e.encounter_id = h.encounter_id

LEFT JOIN procedure_by_encounter AS p
    ON e.encounter_id = p.encounter_id

LEFT JOIN medication_by_encounter AS m
    ON e.encounter_id = m.encounter_id

LEFT JOIN iron_medication_by_encounter AS im
    ON e.encounter_id = im.encounter_id;


-- ============================================================
-- BLOCK 14 — VALIDATE ENCOUNTER WORKFLOW MART
--
-- PURPOSE:
-- Confirm that Block 13 preserved encounter grain and quantify how
-- often target-patient encounters contain CBC or iron-medication
-- workflow signals.
--
-- EXPECTED:
--   mart_rows = unique_encounters
--   duplicate_encounter_rows = 0
-- ============================================================

SELECT
    COUNT(*) AS mart_rows,
    COUNT(DISTINCT encounter_id)
        AS unique_encounters,

    COUNT(*)
    -
    COUNT(DISTINCT encounter_id)
        AS duplicate_encounter_rows,

    COUNT_IF(
        cbc_hematology_observation_flag = 1
    ) AS encounters_with_cbc_hematology_observation,

    COUNT_IF(
        iron_related_medication_flag = 1
    ) AS encounters_with_iron_related_medication

FROM analytics.synthea_target_encounter_workflow_signals;


-- ============================================================
-- BLOCK 15 — CREATE SEGMENT-SPECIFIC PRE/POST ENCOUNTER PATHWAY
--
-- PURPOSE:
-- Place each target-patient encounter into a fixed window relative
-- to that patient's FIRST condition date for EACH clinical segment.
--
-- GRAIN:
--   one row per patient + risk_segment + encounter
--
-- IMPORTANT:
-- Because risk segments overlap, the same encounter may appear once
-- for anemia and again for pregnancy, CKD, or heart failure when a
-- patient belongs to multiple segments. That duplication is
-- intentional and is controlled by explicit grain.
--
-- WINDOWS:
--   PRE-365        = 1–365 days before segment index
--   INDEX-DATE     = same day as segment index
--   POST-365       = 1–365 days after segment index
--   OUTSIDE-WINDOW = all other history
-- ============================================================

CREATE OR REPLACE TABLE analytics.synthea_target_segment_encounter_pathway AS

SELECT
    i.patient_id,
    i.risk_segment,
    i.evidence_category,
    i.first_segment_condition_date,

    w.encounter_id,
    w.service_date,
    w.service_month,
    w.encounter_class,

    w.organization_id,
    w.organization_name,
    w.provider_id,
    w.provider_name,
    w.provider_specialty,
    w.payer_id,

    w.target_condition_encounter_flag,

    w.cbc_hematology_observation_records,
    w.cbc_hematology_observation_flag,

    w.total_procedure_records,
    w.total_medication_records,

    w.iron_related_medication_records,
    w.iron_related_medication_flag,

    DATE_DIFF(
        'day',
        i.first_segment_condition_date,
        w.service_date
    ) AS days_from_segment_index,

    CASE
        WHEN w.service_date BETWEEN
             i.first_segment_condition_date - INTERVAL 365 DAY
             AND i.first_segment_condition_date - INTERVAL 1 DAY
            THEN 'PRE-365'

        WHEN w.service_date = i.first_segment_condition_date
            THEN 'INDEX-DATE'

        WHEN w.service_date BETWEEN
             i.first_segment_condition_date + INTERVAL 1 DAY
             AND i.first_segment_condition_date + INTERVAL 365 DAY
            THEN 'POST-365'

        ELSE 'OUTSIDE-WINDOW'
    END AS pathway_window

FROM analytics.synthea_target_segment_index_date AS i

INNER JOIN analytics.synthea_target_encounter_workflow_signals AS w
    ON i.patient_id = w.patient_id;


-- ============================================================
-- BLOCK 16 — VALIDATE SEGMENT ENCOUNTER PATHWAY
--
-- PURPOSE:
-- Confirm uniqueness at the intended patient + segment + encounter
-- grain and inspect utilization by pathway window.
--
-- EXPECTED:
-- duplicate_patient_segment_encounter_rows = 0
--
-- Note:
-- pathway_rows will exceed distinct encounter IDs because patients can
-- belong to multiple risk segments.
-- ============================================================

SELECT
    COUNT(*) AS pathway_rows,

    COUNT(
        DISTINCT patient_id
        || '|'
        || risk_segment
        || '|'
        || encounter_id
    ) AS unique_patient_segment_encounter_rows,

    COUNT(*)
    -
    COUNT(
        DISTINCT patient_id
        || '|'
        || risk_segment
        || '|'
        || encounter_id
    ) AS duplicate_patient_segment_encounter_rows,

    COUNT(DISTINCT encounter_id)
        AS unique_underlying_encounters

FROM analytics.synthea_target_segment_encounter_pathway;


SELECT
    pathway_window,

    COUNT(*) AS patient_segment_encounter_rows,
    COUNT(DISTINCT patient_id)
        AS unique_patients,

    COUNT(
        DISTINCT patient_id
        || '|'
        || risk_segment
    ) AS patient_segment_memberships

FROM analytics.synthea_target_segment_encounter_pathway

GROUP BY pathway_window

ORDER BY
    CASE pathway_window
        WHEN 'PRE-365' THEN 1
        WHEN 'INDEX-DATE' THEN 2
        WHEN 'POST-365' THEN 3
        ELSE 4
    END;


-- ============================================================
-- BLOCK 17 — CREATE PATIENT-SEGMENT PATHWAY SUMMARY
--
-- PURPOSE:
-- Create one comparable row per patient + clinical segment.
--
-- GRAIN:
--   one row per patient + risk_segment
--
-- UTILIZATION:
-- Encounter counts come from the segment-specific pre/post windows.
--
-- CBC OBSERVATIONS:
-- Patient-level CBC timing is calculated from observation DATE rather
-- than encounter linkage so CBC observations with ENCOUNTER = NULL
-- are still captured.
--
-- IRON MEDICATIONS:
-- Medication timing is calculated directly from medication START.
-- ============================================================

CREATE OR REPLACE TABLE mart.segment_patient_pathway_summary AS

WITH encounter_summary AS (

    SELECT
        patient_id,
        risk_segment,
        first_segment_condition_date,

        COUNT(DISTINCT CASE
            WHEN pathway_window = 'PRE-365'
                THEN encounter_id
        END) AS encounters_pre_365,

        COUNT(DISTINCT CASE
            WHEN pathway_window = 'INDEX-DATE'
                THEN encounter_id
        END) AS encounters_on_index_date,

        COUNT(DISTINCT CASE
            WHEN pathway_window = 'POST-365'
                THEN encounter_id
        END) AS encounters_post_365

    FROM analytics.synthea_target_segment_encounter_pathway

    GROUP BY
        patient_id,
        risk_segment,
        first_segment_condition_date
),

cbc_summary AS (

    SELECT
        i.patient_id,
        i.risk_segment,

        COUNT(DISTINCT CASE
            WHEN o.observation_date BETWEEN
                 i.first_segment_condition_date - INTERVAL 365 DAY
                 AND i.first_segment_condition_date - INTERVAL 1 DAY
                THEN o.observation_date
        END) AS cbc_observation_days_pre_365,

        COUNT(DISTINCT CASE
            WHEN o.observation_date BETWEEN
                 i.first_segment_condition_date
                 AND i.first_segment_condition_date + INTERVAL 365 DAY
                THEN o.observation_date
        END) AS cbc_observation_days_on_or_post_365

    FROM analytics.synthea_target_segment_index_date AS i

    LEFT JOIN analytics.synthea_target_hematology_observation_events AS o
        ON i.patient_id = o.patient_id

    GROUP BY
        i.patient_id,
        i.risk_segment
),

iron_med_summary AS (

    SELECT
        i.patient_id,
        i.risk_segment,

        COUNT(DISTINCT CASE
            WHEN m.medication_start_date BETWEEN
                 i.first_segment_condition_date - INTERVAL 365 DAY
                 AND i.first_segment_condition_date - INTERVAL 1 DAY
                THEN m.medication_start_date
        END) AS iron_medication_start_days_pre_365,

        COUNT(DISTINCT CASE
            WHEN m.medication_start_date BETWEEN
                 i.first_segment_condition_date
                 AND i.first_segment_condition_date + INTERVAL 365 DAY
                THEN m.medication_start_date
        END) AS iron_medication_start_days_on_or_post_365

    FROM analytics.synthea_target_segment_index_date AS i

    LEFT JOIN analytics.synthea_target_iron_medication_events AS m
        ON i.patient_id = m.patient_id

    GROUP BY
        i.patient_id,
        i.risk_segment
)

SELECT
    e.patient_id,
    e.risk_segment,
    e.first_segment_condition_date,

    e.encounters_pre_365,
    e.encounters_on_index_date,
    e.encounters_post_365,

    COALESCE(
        c.cbc_observation_days_pre_365,
        0
    ) AS cbc_observation_days_pre_365,

    COALESCE(
        c.cbc_observation_days_on_or_post_365,
        0
    ) AS cbc_observation_days_on_or_post_365,

    COALESCE(
        m.iron_medication_start_days_pre_365,
        0
    ) AS iron_medication_start_days_pre_365,

    COALESCE(
        m.iron_medication_start_days_on_or_post_365,
        0
    ) AS iron_medication_start_days_on_or_post_365

FROM encounter_summary AS e

LEFT JOIN cbc_summary AS c
    ON e.patient_id = c.patient_id
   AND e.risk_segment = c.risk_segment

LEFT JOIN iron_med_summary AS m
    ON e.patient_id = m.patient_id
   AND e.risk_segment = m.risk_segment;


-- ============================================================
-- BLOCK 18 — VALIDATE PATIENT-SEGMENT PATHWAY SUMMARY
--
-- PURPOSE:
-- Confirm one row per patient-segment membership and compare overall
-- pre/post utilization distributions.
--
-- WHY MEDIAN MATTERS:
-- Median utilization is less sensitive than the mean to very
-- high-utilization synthetic patients.
-- ============================================================

SELECT
    COUNT(*) AS patient_segment_rows,

    COUNT(
        DISTINCT patient_id
        || '|'
        || risk_segment
    ) AS unique_patient_segment_rows,

    COUNT(*)
    -
    COUNT(
        DISTINCT patient_id
        || '|'
        || risk_segment
    ) AS duplicate_patient_segment_rows,

    ROUND(
        AVG(encounters_pre_365),
        2
    ) AS average_pre_365_encounters,

    ROUND(
        MEDIAN(encounters_pre_365),
        2
    ) AS median_pre_365_encounters,

    ROUND(
        AVG(encounters_post_365),
        2
    ) AS average_post_365_encounters,

    ROUND(
        MEDIAN(encounters_post_365),
        2
    ) AS median_post_365_encounters

FROM mart.segment_patient_pathway_summary;


-- ============================================================
-- BLOCK 19 — CREATE UTILIZATION PATHWAY BY CLINICAL SEGMENT
--
-- PURPOSE:
-- Summarize comparable 365-day pre/post utilization around the first
-- condition date for each clinical segment.
--
-- GRAIN:
--   one row per risk_segment
--
-- BUSINESS QUESTION:
-- Which synthetic segments show persistent or increasing utilization
-- after diagnosis and therefore merit deeper real-world economic
-- investigation with MEPS?
--
-- IMPORTANT:
-- Segment populations overlap. Patient counts across rows should not
-- be added together.
-- ============================================================

CREATE OR REPLACE TABLE mart.utilization_pathway_by_segment AS

SELECT
    risk_segment,

    COUNT(DISTINCT patient_id)
        AS unique_patients,

    ROUND(
        AVG(encounters_pre_365),
        2
    ) AS average_encounters_pre_365,

    ROUND(
        MEDIAN(encounters_pre_365),
        2
    ) AS median_encounters_pre_365,

    ROUND(
        AVG(encounters_post_365),
        2
    ) AS average_encounters_post_365,

    ROUND(
        MEDIAN(encounters_post_365),
        2
    ) AS median_encounters_post_365,

    ROUND(
        AVG(
            encounters_post_365
            - encounters_pre_365
        ),
        2
    ) AS average_change_in_encounters,

    COUNT_IF(
        encounters_post_365
        > encounters_pre_365
    ) AS patients_with_higher_post_utilization,

    ROUND(
        100.0
        * COUNT_IF(
            encounters_post_365
            > encounters_pre_365
        )
        / NULLIF(COUNT(*), 0),
        2
    ) AS patients_with_higher_post_utilization_pct,

    COUNT_IF(
        cbc_observation_days_pre_365 > 0
    ) AS patients_with_cbc_pre_365,

    ROUND(
        100.0
        * COUNT_IF(
            cbc_observation_days_pre_365 > 0
        )
        / NULLIF(COUNT(*), 0),
        2
    ) AS patients_with_cbc_pre_365_pct,

    COUNT_IF(
        cbc_observation_days_on_or_post_365 > 0
    ) AS patients_with_cbc_on_or_post_365,

    ROUND(
        100.0
        * COUNT_IF(
            cbc_observation_days_on_or_post_365 > 0
        )
        / NULLIF(COUNT(*), 0),
        2
    ) AS patients_with_cbc_on_or_post_365_pct,

    COUNT_IF(
        iron_medication_start_days_on_or_post_365 > 0
    ) AS patients_with_iron_medication_on_or_post_365

FROM mart.segment_patient_pathway_summary

GROUP BY risk_segment;


-- ============================================================
-- BLOCK 20 — REVIEW UTILIZATION PATHWAY BY SEGMENT
--
-- PURPOSE:
-- Display the main segment-level utilization output.
--
-- INTERPRETATION ORDER:
--   1. Compare medians first.
--   2. Compare averages second.
--   3. Review the share with higher post-index utilization.
--   4. Review CBC workflow penetration.
--   5. Treat iron-medication presence as a supporting signal only.
--
-- Do not convert synthetic encounter counts into real-world burden.
-- ============================================================

SELECT *
FROM mart.utilization_pathway_by_segment
ORDER BY unique_patients DESC;


-- ============================================================
-- BLOCK 21 — CREATE TARGET-CONDITION ENCOUNTER-SETTING MART
--
-- PURPOSE:
-- Identify where mapped target-condition encounters occur.
--
-- GRAIN:
--   one row per encounter_class
--
-- BUSINESS QUESTION — ADOPTION:
-- Which care settings represent the largest synthetic workflow
-- touchpoints for a home iron-status diagnostic?
--
-- CBC SIGNAL:
-- Only encounter-linked CBC observations can be attributed to a
-- specific encounter setting. Patient-level CBC analysis elsewhere in
-- this file also includes observations without encounter IDs.
-- ============================================================

CREATE OR REPLACE TABLE mart.target_condition_encounter_setting AS

SELECT
    encounter_class,

    COUNT(DISTINCT encounter_id)
        AS target_condition_encounters,

    COUNT(DISTINCT patient_id)
        AS unique_target_patients,

    COUNT(DISTINCT organization_id)
        AS organizations,

    COUNT(DISTINCT provider_id)
        AS providers,

    COUNT(DISTINCT CASE
        WHEN cbc_hematology_observation_flag = 1
            THEN encounter_id
    END) AS target_encounters_with_linked_cbc_observation,

    ROUND(
        100.0
        * COUNT(DISTINCT CASE
            WHEN cbc_hematology_observation_flag = 1
                THEN encounter_id
        END)
        / NULLIF(
            COUNT(DISTINCT encounter_id),
            0
        ),
        2
    ) AS target_encounters_with_linked_cbc_observation_pct,

    COUNT(DISTINCT CASE
        WHEN iron_related_medication_flag = 1
            THEN encounter_id
    END) AS target_encounters_with_iron_medication,

    ROUND(
        100.0
        * COUNT(DISTINCT encounter_id)
        / NULLIF(
            SUM(
                COUNT(DISTINCT encounter_id)
            ) OVER (),
            0
        ),
        2
    ) AS share_of_target_condition_encounters_pct

FROM analytics.synthea_target_encounter_workflow_signals

WHERE target_condition_encounter_flag = 1

GROUP BY encounter_class;


-- ============================================================
-- BLOCK 22 — REVIEW TARGET-CONDITION ENCOUNTER SETTINGS
--
-- PURPOSE:
-- Display the adoption-oriented encounter-setting distribution.
--
-- This is a strong dashboard candidate because it links clinical
-- opportunity to a concrete care-delivery setting.
-- ============================================================

SELECT *
FROM mart.target_condition_encounter_setting
ORDER BY target_condition_encounters DESC;


-- ============================================================
-- BLOCK 23 — CREATE WORKFLOW SIGNALS BY CLINICAL SEGMENT
--
-- PURPOSE:
-- Determine how many patients in each clinical segment ever interact
-- with CBC/red-cell testing and iron-treatment workflows.
--
-- GRAIN:
--   one row per risk_segment
--
-- BUSINESS QUESTION:
-- Which high-opportunity populations already have substantial
-- healthcare/testing interaction, suggesting a feasible adoption
-- pathway for additional iron-status testing?
--
-- FERRITIN:
-- No ferritin metric is included because this export contains no
-- ferritin observations. The absence is documented as a dataset
-- limitation rather than interpreted as unmet need.
-- ============================================================

CREATE OR REPLACE TABLE mart.workflow_signal_by_segment AS

WITH cbc_patient AS (

    SELECT
        patient_id,
        1 AS any_cbc_hematology_observation_flag

    FROM analytics.synthea_target_hematology_observation_events

    GROUP BY patient_id
),

iron_med_patient AS (

    SELECT
        patient_id,
        1 AS any_iron_related_medication_flag

    FROM analytics.synthea_target_iron_medication_events

    GROUP BY patient_id
)

SELECT
    i.risk_segment,

    COUNT(DISTINCT i.patient_id)
        AS unique_patients,

    SUM(
        COALESCE(
            c.any_cbc_hematology_observation_flag,
            0
        )
    ) AS patients_with_any_cbc_hematology_observation,

    ROUND(
        100.0
        * SUM(
            COALESCE(
                c.any_cbc_hematology_observation_flag,
                0
            )
        )
        / NULLIF(COUNT(*), 0),
        2
    ) AS patients_with_any_cbc_hematology_observation_pct,

    SUM(
        COALESCE(
            m.any_iron_related_medication_flag,
            0
        )
    ) AS patients_with_any_iron_related_medication,

    ROUND(
        100.0
        * SUM(
            COALESCE(
                m.any_iron_related_medication_flag,
                0
            )
        )
        / NULLIF(COUNT(*), 0),
        2
    ) AS patients_with_any_iron_related_medication_pct

FROM analytics.synthea_target_segment_index_date AS i

LEFT JOIN cbc_patient AS c
    ON i.patient_id = c.patient_id

LEFT JOIN iron_med_patient AS m
    ON i.patient_id = m.patient_id

GROUP BY i.risk_segment;


-- ============================================================
-- BLOCK 24 — REVIEW WORKFLOW SIGNALS BY SEGMENT
--
-- PURPOSE:
-- Display CBC/red-cell and iron-treatment workflow penetration.
--
-- POTENTIAL PRODUCT INTERPRETATION:
-- High patient volume + high CBC interaction suggests an existing
-- clinical workflow where an additional iron-status signal might be
-- operationally integrated.
--
-- Whether there is a REAL testing gap must be established with
-- NHANES, EHR, claims, or laboratory data—not Synthea.
-- ============================================================

SELECT *
FROM mart.workflow_signal_by_segment
ORDER BY unique_patients DESC;


-- ============================================================
-- BLOCK 25 — FINAL RECONCILIATION
--
-- PURPOSE:
-- Confirm that the main a06 analytical objects preserve their intended
-- grains before exporting to Tableau.
--
-- EXPECTED:
--   segment_patient_pathway_rows =
--       unique_segment_patient_pathway_rows
--   utilization_segment_rows = 4
--   workflow_segment_rows = 4
-- ============================================================

SELECT
    (
        SELECT COUNT(*)
        FROM analytics.synthea_target_segment_index_date
    ) AS patient_segment_index_rows,

    (
        SELECT COUNT(*)
        FROM mart.segment_patient_pathway_summary
    ) AS segment_patient_pathway_rows,

    (
        SELECT COUNT(
            DISTINCT patient_id
            || '|'
            || risk_segment
        )
        FROM mart.segment_patient_pathway_summary
    ) AS unique_segment_patient_pathway_rows,

    (
        SELECT COUNT(*)
        FROM analytics.synthea_target_encounter_workflow_signals
    ) AS encounter_workflow_rows,

    (
        SELECT COUNT(DISTINCT encounter_id)
        FROM analytics.synthea_target_encounter_workflow_signals
    ) AS unique_encounter_workflow_rows,

    (
        SELECT COUNT(*)
        FROM mart.utilization_pathway_by_segment
    ) AS utilization_segment_rows,

    (
        SELECT COUNT(*)
        FROM mart.workflow_signal_by_segment
    ) AS workflow_segment_rows;


-- ============================================================
-- BLOCK 26 — EXPORT UTILIZATION PATHWAY BY SEGMENT
--
-- PURPOSE:
-- Create the Tableau-ready fixed-window utilization dataset.
-- ============================================================

COPY mart.utilization_pathway_by_segment
TO 'outputs/marts/utilization_pathway_by_segment.csv'
WITH (
    HEADER true,
    DELIMITER ','
);


-- ============================================================
-- BLOCK 27 — EXPORT TARGET-CONDITION ENCOUNTER SETTINGS
--
-- PURPOSE:
-- Create a Tableau-ready adoption dataset showing where target
-- condition encounters occur.
-- ============================================================

COPY mart.target_condition_encounter_setting
TO 'outputs/marts/target_condition_encounter_setting.csv'
WITH (
    HEADER true,
    DELIMITER ','
);


-- ============================================================
-- BLOCK 28 — EXPORT WORKFLOW SIGNALS BY SEGMENT
--
-- PURPOSE:
-- Create a Tableau-ready dataset showing CBC/red-cell and iron-
-- treatment workflow penetration by clinical segment.
-- ============================================================

COPY mart.workflow_signal_by_segment
TO 'outputs/marts/workflow_signal_by_segment.csv'
WITH (
    HEADER true,
    DELIMITER ','
);


-- ============================================================
-- BLOCK 29 — EXPORT PATIENT-SEGMENT PATHWAY SUMMARY FOR QA
--
-- PURPOSE:
-- Save the patient-segment level pathway dataset for QA and deeper
-- analysis. This is not intended as a headline dashboard source.
-- ============================================================

COPY mart.segment_patient_pathway_summary
TO 'outputs/qa/segment_patient_pathway_summary.csv'
WITH (
    HEADER true,
    DELIMITER ','
);
