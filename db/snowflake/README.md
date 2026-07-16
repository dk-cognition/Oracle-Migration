# Snowflake target (migrated artifacts)

This directory holds the migrated, Snowflake-native artifacts. Filenames mirror
the Oracle sources in `db/oracle/`:

```
db/snowflake/
├── 01_schema.sql       -- DDL rewritten for Snowflake (NUMBER/TIMESTAMP_NTZ, AUTOINCREMENT, sequences; no tablespaces/indexes)
├── 02_packages.sql     -- claims_pkg split into standalone Snowflake procedures / UDFs (trigger logic folded into column defaults)
├── 03_views.sql        -- views with ANSI joins, QUALIFY, CASE (no (+)/ROWNUM/DECODE)
└── 04_seed_data.sql    -- seed data using CURRENT_TIMESTAMP / TO_DATE, no DUAL
```

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent.
