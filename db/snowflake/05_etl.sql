--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake ETL objects replacing the legacy flat-file extract
-- (NightlyExtract + scripts/export_oracle_to_stage.sh: SQL*Plus spool -> SFTP).
--
-- Two patterns are provided:
--   1. Stage + COPY INTO (used by NightlyExtract.java) -- direct unload to a
--      named stage, no flat-file/SFTP hop.
--   2. Stream + Task -- true CDC on the claim table, replacing the
--      TRUNC(SYSDATE) - 1 window logic entirely. A Snowpipe definition is
--      included (commented) for continuous loads from an external stage.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

--------------------------------------------------------------------------------
-- 1. Named stage + file format for the claims feed.
--------------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT ff_claims_psv
  TYPE = CSV
  FIELD_DELIMITER = '|'
  NULL_IF = ('');

CREATE OR REPLACE STAGE claims_stage
  FILE_FORMAT = ff_claims_psv
  COMMENT = 'Landing stage for the nightly claims feed (replaces SFTP drop)';

-- Ad-hoc / scheduled unload (same statement NightlyExtract.java issues):
-- COPY INTO @claims_stage/nightly/claims_
--   FROM (
--     SELECT cl.claim_id, cl.claim_number, cl.policy_id,
--            TO_VARCHAR(cl.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,
--            cl.status, cl.reserve_amount, cl.paid_amount
--       FROM claim cl
--      WHERE cl.reported_date >= DATEADD('day', -1, CURRENT_DATE())
--      ORDER BY cl.claim_id
--   )
--   FILE_FORMAT = (FORMAT_NAME = ff_claims_psv)
--   OVERWRITE = TRUE;

--------------------------------------------------------------------------------
-- 2. Stream + Task: CDC feed of changed claims (inserts AND updates),
--    removing the "since midnight yesterday" window approximation.
--------------------------------------------------------------------------------
CREATE OR REPLACE STREAM claim_changes ON TABLE claim;

CREATE OR REPLACE TASK task_export_claim_changes
  WAREHOUSE = CLAIMS_WH
  SCHEDULE = 'USING CRON 0 2 * * * UTC'   -- nightly at 02:00 UTC
  WHEN SYSTEM$STREAM_HAS_DATA('CLAIM_CHANGES')
AS
COPY INTO @claims_stage/cdc/claims_
  FROM (
    SELECT c.claim_id, c.claim_number, c.policy_id,
           TO_VARCHAR(c.reported_date, 'YYYY-MM-DD HH24:MI:SS') AS reported,
           c.status, c.reserve_amount, c.paid_amount
      FROM claim_changes c
     WHERE c.METADATA$ACTION = 'INSERT'
  )
  FILE_FORMAT = (FORMAT_NAME = ff_claims_psv)
  INCLUDE_QUERY_ID = TRUE;

-- Tasks are created suspended; enable with:
-- ALTER TASK task_export_claim_changes RESUME;

--------------------------------------------------------------------------------
-- Optional: Snowpipe for continuous load INTO Snowflake when upstream systems
-- drop files on an external stage (S3/Azure/GCS). Uncomment and point at the
-- external stage to activate.
--------------------------------------------------------------------------------
-- CREATE PIPE pipe_claims_load
--   AUTO_INGEST = TRUE
-- AS
-- COPY INTO claim (claim_id, claim_number, policy_id, reported_date,
--                  status, reserve_amount, paid_amount)
--   FROM @claims_ext_stage/inbound/
--   FILE_FORMAT = (FORMAT_NAME = ff_claims_psv);
