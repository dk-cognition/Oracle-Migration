# Snowflake target

Snowflake-native artifacts migrated from `db/oracle/`. Apply in order:

```
db/snowflake/
├── 01_schema.sql       -- DDL rewritten for Snowflake (NUMBER/TIMESTAMP_NTZ, IDENTITY, sequences)
├── 02_procedures.sql   -- claims_pkg re-implemented as Snowflake Scripting procedures + SQL UDFs
├── 03_views.sql        -- views with ANSI joins, QUALIFY, CASE (no (+)/ROWNUM/DECODE)
├── 04_streams_tasks.sql-- trigger/ETL logic re-expressed as Streams + Tasks + Snowpipe
└── 04_seed_data.sql    -- seed data using CURRENT_TIMESTAMP / TO_DATE
```

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent.
