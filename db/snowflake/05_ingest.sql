--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Stage / file format / COPY INTO / Snowpipe definitions replacing the legacy
-- flat-file ETL (docs/MIGRATION.md section 8).
--
-- Replaces: scripts/export_oracle_to_stage.sh (SQL*Plus spool + SFTP) and the
-- pipe-delimited output of NightlyExtract. Data now moves cloud-storage ->
-- Snowflake with COPY INTO for backfill and Snowpipe for continuous load, and
-- the outbound warehouse feed is unloaded straight from the claim CDC stream
-- (see 04_streams_tasks.sql).
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- File format matching the legacy pipe-delimited (.psv) files, so existing
-- upstream producers can be cut over without changing their output.
--------------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT hartford.claims.ff_claims_psv
  TYPE = CSV
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 0
  TRIM_SPACE = TRUE
  NULL_IF = ('', 'NULL')
  EMPTY_FIELD_AS_NULL = TRUE
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

--------------------------------------------------------------------------------
-- External stage on the landing bucket. STORAGE_INTEGRATION carries the cloud
-- credentials, so no keys live in this repo.
--------------------------------------------------------------------------------
CREATE OR REPLACE STAGE hartford.claims.claims_stage
  STORAGE_INTEGRATION = claims_s3_int
  URL = 's3://hartford-claims-landing/'
  FILE_FORMAT = hartford.claims.ff_claims_psv;

--------------------------------------------------------------------------------
-- Backfill / re-load: COPY INTO per table.
--------------------------------------------------------------------------------
COPY INTO hartford.claims.customer
       (customer_id, first_name, last_name, ssn, date_of_birth, email, phone,
        created_ts, updated_ts, risk_score, lifetime_premium, notes)
  FROM @hartford.claims.claims_stage/customer/
  FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv)
  ON_ERROR = ABORT_STATEMENT;

COPY INTO hartford.claims.agent (agent_id, agent_name, manager_id, region_code, hire_date)
  FROM @hartford.claims.claims_stage/agent/
  FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv)
  ON_ERROR = ABORT_STATEMENT;

COPY INTO hartford.claims.policy
       (policy_id, policy_number, customer_id, agent_id, product_code, status,
        effective_date, expiration_date, annual_premium, coverage_limit,
        deductible, created_ts)
  FROM @hartford.claims.claims_stage/policy/
  FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv)
  ON_ERROR = ABORT_STATEMENT;

COPY INTO hartford.claims.claim
       (claim_id, claim_number, policy_id, loss_date, reported_date, claim_type,
        status, reserve_amount, paid_amount, adjuster_id, description)
  FROM @hartford.claims.claims_stage/claim/
  FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv)
  ON_ERROR = ABORT_STATEMENT;

COPY INTO hartford.claims.claim_payment
       (payment_id, claim_id, payment_date, amount, payment_method, check_number)
  FROM @hartford.claims.claims_stage/claim_payment/
  FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv)
  ON_ERROR = ABORT_STATEMENT;

--------------------------------------------------------------------------------
-- Continuous load: Snowpipe on the two high-volume tables. Cloud-storage event
-- notifications trigger these, so there is no nightly window to schedule.
--------------------------------------------------------------------------------
CREATE OR REPLACE PIPE hartford.claims.pipe_claim
  AUTO_INGEST = TRUE
AS
COPY INTO hartford.claims.claim
       (claim_id, claim_number, policy_id, loss_date, reported_date, claim_type,
        status, reserve_amount, paid_amount, adjuster_id, description)
  FROM @hartford.claims.claims_stage/claim/
  FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv);

CREATE OR REPLACE PIPE hartford.claims.pipe_claim_payment
  AUTO_INGEST = TRUE
AS
COPY INTO hartford.claims.claim_payment
       (payment_id, claim_id, payment_date, amount, payment_method, check_number)
  FROM @hartford.claims.claims_stage/claim_payment/
  FILE_FORMAT = (FORMAT_NAME = hartford.claims.ff_claims_psv);
