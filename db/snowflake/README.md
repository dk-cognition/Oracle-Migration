# Snowflake target

Snowflake-native artifacts produced by the Oracle 19c → Snowflake migration.
Run in numeric order against `HARTFORD.CLAIMS` with the `CLAIMS_WH` warehouse:

```
db/snowflake/
├── 01_schema.sql        -- DDL: NUMBER/TIMESTAMP_NTZ/VARCHAR types, sequences as column DEFAULTs, no tablespaces/indexes
├── 02_procedures.sql    -- claims_pkg as Snowflake Scripting procedures + SQL UDFs
├── 03_views.sql         -- views with LEFT JOIN, QUALIFY, CASE, COALESCE (no (+)/ROWNUM/DECODE/NVL)
├── 04_streams_tasks.sql -- trigger logic (updated_ts, payment application) as Streams + Tasks
├── 05_stage_pipe.sql    -- stages, file format, COPY INTO bulk load, Snowpipe (replaces the flat-file ETL)
└── 06_seed_data.sql     -- seed data using TO_TIMESTAMP_NTZ and CALL
```

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent.
