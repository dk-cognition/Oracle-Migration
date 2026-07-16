# Snowflake target (migrated)

Snowflake-native artifacts produced by the Oracle → Snowflake migration:

```
db/snowflake/
├── 01_schema.sql       -- DDL rewritten for Snowflake (VARCHAR/NUMBER/TIMESTAMP_NTZ, AUTOINCREMENT, sequence)
├── 02_procedures.sql   -- claims_pkg re-implemented as Snowflake Scripting procedures + SQL UDFs
├── 03_views.sql        -- views with ANSI joins, QUALIFY, CASE (no (+)/ROWNUM/DECODE)
├── 04_streams_tasks.sql-- trigger / CDC logic re-expressed as Streams + Tasks
└── 04_seed_data.sql    -- seed data using CURRENT_TIMESTAMP / TO_DATE and CALL <proc>
```

Suggested apply order: `01_schema.sql` → `02_procedures.sql` → `03_views.sql` →
`04_streams_tasks.sql` → `04_seed_data.sql`.

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent.
