--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Streams + Tasks: Snowflake-native replacement for Oracle row-level triggers
-- and MV fast-refresh, plus the Snowpipe objects that replace the flat-file ETL.
--
--   * trg_customer_biu (PK + created_ts on insert) -> column DEFAULTs
--     (see 01_schema.sql); the "updated_ts on UPDATE" half is handled here.
--   * trg_policy_bi -> policy_id AUTOINCREMENT (see 01_schema.sql).
--   * mv_daily_paid REFRESH FAST ON COMMIT -> Snowflake MVs auto-maintain;
--     no task needed (kept as a note below).
--   * NightlyExtract / export_oracle_to_stage.sh flat files -> stage + Snowpipe
--     and a Stream for CDC-style incremental consumption.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- updated_ts maintenance (replaces the UPDATE half of trg_customer_biu).
-- Writers should set updated_ts = CURRENT_TIMESTAMP() themselves (the app's
-- customer_upsert does); this Stream + Task pair backstops writers that don't.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM str_customer_changes ON TABLE customer;

CREATE OR REPLACE TASK tsk_touch_customer_updated_ts
  WAREHOUSE = CLAIMS_WH
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('STR_CUSTOMER_CHANGES')
AS
  MERGE INTO customer tgt
  USING (
    SELECT DISTINCT customer_id
      FROM str_customer_changes
     WHERE METADATA$ACTION = 'INSERT'
       AND METADATA$ISUPDATE = TRUE
  ) src
     ON tgt.customer_id = src.customer_id
   WHEN MATCHED THEN UPDATE SET tgt.updated_ts = CURRENT_TIMESTAMP();

ALTER TASK tsk_touch_customer_updated_ts RESUME;

--------------------------------------------------------------------------------
-- mv_daily_paid: no task required. Snowflake materialized views are
-- auto-maintained (the Oracle REFRESH FAST ON COMMIT semantics are built in).
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Snowpipe load path (replaces NightlyExtract + export_oracle_to_stage.sh).
-- Upstream systems land pipe-delimited files on the stage; Snowpipe ingests
-- them continuously - no SQL*Plus spool, no SFTP hop.
--------------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT ff_claims_psv
  TYPE = 'CSV'
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 0
  EMPTY_FIELD_AS_NULL = TRUE
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

CREATE STAGE IF NOT EXISTS claims_stage
  FILE_FORMAT = ff_claims_psv
  COMMENT = 'Landing zone for inbound claim feeds (was the SFTP drop).';

CREATE OR REPLACE PIPE pipe_claims_load
  AUTO_INGEST = TRUE
AS
  COPY INTO claim (claim_id, claim_number, policy_id, loss_date, reported_date,
                   claim_type, status, reserve_amount, paid_amount, description)
  FROM @claims_stage/claims/
  FILE_FORMAT = (FORMAT_NAME = ff_claims_psv);

--------------------------------------------------------------------------------
-- CDC for the downstream warehouse feed (replaces TRUNC(SYSDATE) - 1 window
-- logic): the Stream tracks exactly the rows that changed since the last
-- consumption, so the nightly export no longer needs a date-window predicate.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM str_claim_changes ON TABLE claim;

CREATE OR REPLACE TASK tsk_export_changed_claims
  WAREHOUSE = CLAIMS_WH
  SCHEDULE = 'USING CRON 15 2 * * * UTC'   -- nightly, replaces the batch job
  WHEN SYSTEM$STREAM_HAS_DATA('STR_CLAIM_CHANGES')
AS
  COPY INTO @claims_stage/outbound/claims_extract_
  FROM (
    SELECT claim_id, claim_number, policy_id,
           TO_VARCHAR(reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,
           status, reserve_amount, paid_amount
      FROM str_claim_changes
     WHERE METADATA$ACTION = 'INSERT'
     ORDER BY claim_id
  )
  FILE_FORMAT = (FORMAT_NAME = ff_claims_psv)
  OVERWRITE = FALSE;

ALTER TASK tsk_export_changed_claims RESUME;
