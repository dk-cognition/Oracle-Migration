# Snowflake target (to be built during the migration)

This directory is intentionally empty except for this note. It is the landing
zone for the migrated, Snowflake-native artifacts that the demo produces:

```
db/snowflake/
├── 01_schema.sql       -- DDL rewritten for Snowflake (NUMBER/TIMESTAMP, IDENTITY, sequences)
├── 02_procedures.sql   -- claims_pkg re-implemented as Snowflake Scripting procedures
├── 03_views.sql        -- views with ANSI joins, QUALIFY, CASE (no (+)/ROWNUM/DECODE)
├── 04_streams_tasks.sql-- trigger logic re-expressed as Streams + Tasks
└── 04_seed_data.sql    -- seed data using CURRENT_TIMESTAMP / TO_DATE
```

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent.
