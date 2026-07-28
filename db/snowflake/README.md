# Snowflake target (produced by the migration)

Snowflake-native artifacts, mirroring the source filenames in `../oracle/` so each
rewrite diffs against its Oracle original:

```
db/snowflake/
├── 01_schema.sql      -- DDL: VARCHAR/NUMBER/FLOAT/TIMESTAMP_NTZ, sequence &
│                         AUTOINCREMENT defaults, no tablespaces, no indexes
├── 02_packages.sql    -- claims_pkg split into procedures / UDFs, config table
│                         for g_default_reserve, Stream + Task for updated_ts
├── 03_views.sql       -- ANSI joins, CASE, COALESCE, QUALIFY, recursive CTE,
│                         auto-maintained materialized view
└── 04_seed_data.sql   -- seed data via TO_TIMESTAMP_NTZ + CALL of the procedures
```

Apply them in file order (`01` → `04`).

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent.
