--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Stage + file format for the nightly extract. Replaces the Oracle SQL*Plus
-- spool -> .psv -> SFTP hop: NightlyExtract and scripts/export_oracle_to_stage.sh
-- now run COPY INTO @claims_extract_stage directly inside Snowflake.
--------------------------------------------------------------------------------

USE SCHEMA HARTFORD.CLAIMS;

-- Same layout the downstream feed already consumes: pipe-delimited, no header,
-- NULL written as an empty field, uncompressed .psv files.
CREATE FILE FORMAT IF NOT EXISTS psv_format
  TYPE = CSV
  FIELD_DELIMITER = '|'
  FIELD_OPTIONALLY_ENCLOSED_BY = NONE
  NULL_IF = ('')
  EMPTY_FIELD_AS_NULL = TRUE
  COMPRESSION = NONE
  FILE_EXTENSION = 'psv';

-- Internal named stage. To deliver to cloud storage instead, replace with an
-- external stage backed by a storage integration, e.g.:
--   CREATE STAGE claims_extract_stage
--     URL = 's3://<bucket>/claims-feed/'
--     STORAGE_INTEGRATION = <integration_name>
--     FILE_FORMAT = psv_format;
CREATE STAGE IF NOT EXISTS claims_extract_stage
  FILE_FORMAT = psv_format;
