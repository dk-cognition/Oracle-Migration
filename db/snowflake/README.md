# Snowflake target

Migrated, Snowflake-native artifacts produced by the demo. Apply in order:

```
db/snowflake/
├── 01_schema.sql        -- DDL rewritten for Snowflake (VARCHAR/TIMESTAMP_NTZ, sequences as column DEFAULTs)
├── 02_procedures.sql    -- claims_pkg re-implemented as Snowflake Scripting procedures + UDFs
├── 03_views.sql         -- views with ANSI joins, QUALIFY, CASE (no (+)/ROWNUM/DECODE)
├── 04_streams_tasks.sql -- trigger logic re-expressed as Streams + Tasks
└── 05_stage_and_pipe.sql-- stage, file format, COPY INTO + Snowpipe replacing the flat-file ETL
```

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent.
