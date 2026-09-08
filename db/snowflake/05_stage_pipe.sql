--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Stages, file formats, COPY INTO and Snowpipe objects that replace the legacy
-- flat-file ETL (NightlyExtract.java + scripts/export_oracle_to_stage.sh).
--
--   Legacy:  SQL*Plus SPOOL -> *.psv -> SFTP -> warehouse
--   Now:     (a) one-time bulk migration of Oracle extracts: COPY INTO <table> FROM @claims_stage
--            (b) continuous inbound payments: Snowpipe -> claim_payment_landing -> Task
--            (c) nightly outbound changed-claims feed: COPY INTO @claims_export (NightlyExtract)
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- File format matching the legacy pipe-delimited extracts.
--------------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT ff_psv
  TYPE = 'CSV'
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 0
  NULL_IF = ('', 'NULL')
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = TRUE
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS'
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE;

--------------------------------------------------------------------------------
-- Inbound stage (S3 bucket the legacy SFTP job used to drop files into).
--------------------------------------------------------------------------------
CREATE STORAGE INTEGRATION IF NOT EXISTS int_hartford_claims_s3
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::000000000000:role/hartford-claims-snowflake'
  STORAGE_ALLOWED_LOCATIONS = ('s3://hartford-claims-feeds/');

CREATE OR REPLACE STAGE claims_stage
  URL = 's3://hartford-claims-feeds/inbound/'
  STORAGE_INTEGRATION = int_hartford_claims_s3
  FILE_FORMAT = ff_psv;

CREATE OR REPLACE STAGE claims_export
  URL = 's3://hartford-claims-feeds/outbound/'
  STORAGE_INTEGRATION = int_hartford_claims_s3
  FILE_FORMAT = ff_psv;

--------------------------------------------------------------------------------
-- (a) One-time bulk load of the Oracle extracts (customer, agent, policy,
--     claim, claim_payment as <table>.psv). Run once during cut-over.
--------------------------------------------------------------------------------
COPY INTO agent         FROM @claims_stage/agent.psv         ON_ERROR = 'ABORT_STATEMENT';
COPY INTO customer      FROM @claims_stage/customer.psv      ON_ERROR = 'ABORT_STATEMENT';
COPY INTO policy        FROM @claims_stage/policy.psv        ON_ERROR = 'ABORT_STATEMENT';
COPY INTO claim         FROM @claims_stage/claim.psv         ON_ERROR = 'ABORT_STATEMENT';
COPY INTO claim_payment FROM @claims_stage/claim_payment.psv ON_ERROR = 'ABORT_STATEMENT';

-- Re-seat sequences above the migrated key ranges (Snowflake cannot ALTER a
-- sequence's start value, so recreate them once the loaded MAX() is known):
-- CREATE OR REPLACE SEQUENCE seq_customer_id START WITH <MAX(customer_id)+1>;
-- CREATE OR REPLACE SEQUENCE seq_policy_id   START WITH <MAX(policy_id)+1>;
-- CREATE OR REPLACE SEQUENCE seq_claim_id    START WITH <MAX(claim_id)+1>;
-- CREATE OR REPLACE SEQUENCE seq_payment_id  START WITH <MAX(payment_id)+1>;

--------------------------------------------------------------------------------
-- (b) Snowpipe: continuous load of externally sourced payment files
--     (s3://hartford-claims-feeds/inbound/payments/*.psv) into the landing table.
--     tk_apply_landed_payments (04_streams_tasks.sql) applies them to claim.
--------------------------------------------------------------------------------
CREATE OR REPLACE PIPE pipe_claim_payments
  AUTO_INGEST = TRUE
AS
  COPY INTO claim_payment_landing (claim_id, payment_date, amount, payment_method, check_number, source_file)
  FROM (
    SELECT $1, $2, $3, $4, $5, METADATA$FILENAME
      FROM @claims_stage/payments/
  )
  FILE_FORMAT = (FORMAT_NAME = ff_psv)
  ON_ERROR = 'SKIP_FILE';

-- After creating the pipe, wire the S3 event notification to the SQS ARN from:
--   SHOW PIPES LIKE 'pipe_claim_payments';   -- notification_channel column

--------------------------------------------------------------------------------
-- (c) Nightly outbound feed of changed claims (executed by NightlyExtract.java).
--     Unloads directly to @claims_export; no local file, no SFTP. The statement
--     lives in src/main/resources/sql/reports.sql as "changed_claims_export".
--------------------------------------------------------------------------------
