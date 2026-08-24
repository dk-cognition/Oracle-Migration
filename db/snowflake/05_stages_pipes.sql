--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Cloud-stage file format, external stage, and Snowpipe definitions.
--
-- Replace the bucket and storage integration placeholders for the target
-- account before applying this file. Snowpipe loads claim/customer files
-- continuously; the batch loader also supports idempotent COPY INTO loads.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

CREATE OR REPLACE FILE FORMAT hartford.claims_pipe_format
  TYPE = CSV
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL');

CREATE OR REPLACE STAGE hartford.claims_stage
  URL = 's3://<hartford-claims-bucket>/'
  STORAGE_INTEGRATION = HARTFORD_CLAIMS_STORAGE_INTEGRATION_PLACEHOLDER;

CREATE OR REPLACE PIPE hartford.claim_load_pipe
  AUTO_INGEST = TRUE
AS
  COPY INTO hartford.claim (
    claim_id, claim_number, policy_id, loss_date, reported_date,
    claim_type, status, reserve_amount, paid_amount, adjuster_id, description
  )
  FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
      FROM @hartford.claims_stage/claim/
  )
  FILE_FORMAT = (FORMAT_NAME = hartford.claims_pipe_format)
  PATTERN = '.*claim.*[.]psv';

CREATE OR REPLACE PIPE hartford.customer_load_pipe
  AUTO_INGEST = TRUE
AS
  COPY INTO hartford.customer (
    customer_id, first_name, last_name, ssn, date_of_birth, email, phone,
    created_ts, updated_ts, risk_score, lifetime_premium, notes
  )
  FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12
      FROM @hartford.claims_stage/customer/
  )
  FILE_FORMAT = (FORMAT_NAME = hartford.claims_pipe_format)
  PATTERN = '.*customer.*[.]psv';
