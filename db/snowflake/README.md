# Snowflake target

The migrated, Snowflake-native artifacts. Deploy in filename order:

```
db/snowflake/
├── 01_schema.sql        -- DDL (NUMBER/TIMESTAMP_NTZ, sequences via column DEFAULTs, claims_config)
├── 02_procedures.sql    -- claims_pkg re-implemented as Scripting procedures + scalar UDFs
├── 03_views.sql         -- views with ANSI joins, QUALIFY, CASE, WITH RECURSIVE, and mv_daily_paid
├── 04_streams_tasks.sql -- trigger logic as Streams + Tasks (needs 05_ingest.sql for the export task)
├── 04_seed_data.sql     -- seed data using CURRENT_TIMESTAMP / TO_DATE
└── 05_ingest.sql        -- stage, file format, COPY INTO backfill, Snowpipes
```

`db/oracle/` is kept as the source-system reference; see
[`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the construct-by-construct
mapping and the item-by-item migration status.
