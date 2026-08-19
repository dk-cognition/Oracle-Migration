--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Stages, file formats, and Snowpipe -- replaces the SQL*Plus spool + SFTP hop
-- implemented by scripts/export_oracle_to_stage.sh.
--
-- Migration notes (see docs/MIGRATION.md):
--   * Outbound: COPY INTO @claims_stage (see etl/NightlyExtract) writes gzipped
--     delimited files straight to cloud storage; nothing is written to a local
--     filesystem and nothing is SFTP'd.
--   * Inbound: Snowpipe auto-ingests any file landing in the same stage, so the
--     nightly cadence becomes continuous load.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

CREATE OR REPLACE FILE FORMAT ff_claims_psv
  TYPE = CSV
  COMPRESSION = GZIP
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 1
  NULL_IF = ('')
  EMPTY_FIELD_AS_NULL = FALSE
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

--------------------------------------------------------------------------------
-- External stage backed by the warehouse feed bucket.
-- Replace the STORAGE_INTEGRATION / URL with the account's own values.
--------------------------------------------------------------------------------
CREATE OR REPLACE STAGE claims_stage
  URL = 's3://hartford-claims-feed/'
  STORAGE_INTEGRATION = claims_feed_integration
  FILE_FORMAT = ff_claims_psv;

--------------------------------------------------------------------------------
-- Inbound loads: Snowpipe replaces the nightly file drop + loader job.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim_inbound (
  claim_id       NUMBER(12),
  claim_number   VARCHAR(24),
  policy_id      NUMBER(12),
  reported_date  TIMESTAMP_NTZ,
  status         VARCHAR(16),
  reserve_amount NUMBER(14,2),
  paid_amount    NUMBER(14,2),
  loaded_ts      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PIPE pipe_claim_inbound
  AUTO_INGEST = TRUE
AS
  COPY INTO claim_inbound (
    claim_id, claim_number, policy_id, reported_date, status,
    reserve_amount, paid_amount
  )
  FROM @claims_stage/inbound/
  FILE_FORMAT = (FORMAT_NAME = ff_claims_psv)
  ON_ERROR = SKIP_FILE;

-- Bulk (re)load equivalent of the old per-table spool loop, for backfills:
--
--   COPY INTO claim_inbound FROM @claims_stage/inbound/
--     FILE_FORMAT = (FORMAT_NAME = ff_claims_psv) FORCE = TRUE;
