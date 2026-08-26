--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Stage, file format, and Snowpipe replacing the legacy flat-file ETL
-- (NightlyExtract.java + scripts/export_oracle_to_stage.sh).
--
-- Old pattern: JDBC read from Oracle -> pipe-delimited .psv -> SFTP -> warehouse.
-- New pattern: files land in a stage and are loaded with COPY INTO; Snowpipe
-- auto-ingests claim files continuously, eliminating the flat-file hop.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

--------------------------------------------------------------------------------
-- File format matching the legacy pipe-delimited extracts.
--------------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT hartford.ff_psv
  TYPE = 'CSV'
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 0
  NULL_IF = ('')
  EMPTY_FIELD_AS_NULL = TRUE
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

--------------------------------------------------------------------------------
-- Stage for inbound claim feeds. Internal stage shown for the demo; swap for an
-- external stage (S3/Azure/GCS + storage integration) in production, which is
-- required for Snowpipe auto-ingest.
--------------------------------------------------------------------------------
CREATE OR REPLACE STAGE hartford.claims_stage
  FILE_FORMAT = hartford.ff_psv
  COMMENT = 'Landing stage for claim/customer/policy feed files';

--------------------------------------------------------------------------------
-- One-time / batch load: COPY INTO from staged files.
-- Run after PUT-ing files to the stage (see scripts/load_stage_to_snowflake.sh).
--------------------------------------------------------------------------------
-- COPY INTO hartford.customer      FROM @hartford.claims_stage/customer/      ON_ERROR = 'ABORT_STATEMENT';
-- COPY INTO hartford.agent         FROM @hartford.claims_stage/agent/         ON_ERROR = 'ABORT_STATEMENT';
-- COPY INTO hartford.policy        FROM @hartford.claims_stage/policy/        ON_ERROR = 'ABORT_STATEMENT';
-- COPY INTO hartford.claim         FROM @hartford.claims_stage/claim/         ON_ERROR = 'ABORT_STATEMENT';
-- COPY INTO hartford.claim_payment FROM @hartford.claims_stage/claim_payment/ ON_ERROR = 'ABORT_STATEMENT';

--------------------------------------------------------------------------------
-- Snowpipe: continuous load of claim feed files as they land on the stage.
-- With an external stage, enable AUTO_INGEST = TRUE and wire the cloud event
-- notifications; with an internal stage, call insertFiles via the REST API.
--------------------------------------------------------------------------------
CREATE OR REPLACE PIPE hartford.pipe_claim_feed
  COMMENT = 'Continuous ingest of claim feed files'
AS
  COPY INTO hartford.claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, adjuster_id, description
  )
  FROM @hartford.claims_stage/claim/
  FILE_FORMAT = (FORMAT_NAME = 'hartford.ff_psv');
