--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Stage + file format for the nightly warehouse feed. Replaces the Oracle
-- SQL*Plus spool -> .psv -> SFTP hop: NightlyExtract and
-- scripts/unload_to_stage.sh run COPY INTO @claims_extract_stage inside
-- Snowflake, so no flat file is ever written by the application host.
--------------------------------------------------------------------------------

USE SCHEMA hartford.claims;

-- Same layout the downstream feed already consumes: pipe-delimited, no header,
-- NULL written as an empty field, uncompressed .psv. Embedded '|' / newlines
-- are backslash-escaped (ESCAPE_UNENCLOSED_FIELD default), which the legacy
-- spool did not do.
CREATE FILE FORMAT IF NOT EXISTS hartford.claims.claims_psv_ff
  TYPE = CSV
  FIELD_DELIMITER = '|'
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE
  NULL_IF = ('')
  EMPTY_FIELD_AS_NULL = TRUE
  COMPRESSION = NONE
  FILE_EXTENSION = 'psv';

-- Internal named stage. Downstream consumers pull with GET or read it from a
-- Snowflake share. To deliver to cloud storage instead (S3 bucket the
-- warehouse team already reads), have ACCOUNTADMIN create a storage
-- integration and swap the stage definition:
--
--   CREATE STORAGE INTEGRATION claims_feed_s3_int
--     TYPE = EXTERNAL_STAGE
--     STORAGE_PROVIDER = 'S3'
--     ENABLED = TRUE
--     STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<account-id>:role/<snowflake-claims-feed-role>'
--     STORAGE_ALLOWED_LOCATIONS = ('s3://<claims-feed-bucket>/claims/');
--
--   CREATE OR REPLACE STAGE hartford.claims.claims_extract_stage
--     URL = 's3://<claims-feed-bucket>/claims/'
--     STORAGE_INTEGRATION = claims_feed_s3_int
--     FILE_FORMAT = hartford.claims.claims_psv_ff;
--
-- A downstream Snowflake account can then ingest continuously with Snowpipe
-- (CREATE PIPE ... AUTO_INGEST = TRUE AS COPY INTO <table> FROM @<its stage>).
CREATE STAGE IF NOT EXISTS hartford.claims.claims_extract_stage
  FILE_FORMAT = hartford.claims.claims_psv_ff;
