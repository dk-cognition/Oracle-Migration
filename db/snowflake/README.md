# Snowflake target (migrated)

Snowflake-native artifacts produced by the Oracle → Snowflake migration:

```
db/snowflake/
├── 01_schema.sql        -- DDL (VARCHAR/NUMBER/TIMESTAMP_NTZ, sequence defaults, no indexes)
├── 02_procedures.sql    -- claims_pkg re-implemented as Snowflake Scripting procedures/UDFs
├── 03_views.sql         -- views with ANSI joins, QUALIFY, CASE + auto-maintained MV
├── 04_streams_tasks.sql -- trigger logic re-expressed as Streams + Tasks
└── 04_seed_data.sql     -- seed data using TO_TIMESTAMP_NTZ / CURRENT_TIMESTAMP + CALLs
```

Apply them in the order `01 → 02 → 03 → 04_streams_tasks → 04_seed_data`.

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent.
