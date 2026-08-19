# Snowflake target

Snowflake-native artifacts migrated from `db/oracle/`. Apply in numeric order:

```
db/snowflake/
├── 01_schema.sql          -- tables, sequences, constraints (no tablespaces/indexes)
├── 02_procedures.sql      -- claims_pkg re-implemented as procedures + UDFs
├── 03_views.sql           -- views with ANSI joins, QUALIFY, CASE + materialized view
├── 04_streams_tasks.sql   -- trigger logic and claim CDC as Streams + Tasks
└── 05_stages_snowpipe.sql -- stage, file format, and auto-ingest pipe for the ETL
```

Historical data is not seeded here: `db/oracle/04_seed_data.sql` is Oracle
demo data, and a real cutover loads production data via bulk unload → `COPY INTO`.

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent and the per-account values
(account identifier, warehouse, stage URL, storage integration) still to be set.
