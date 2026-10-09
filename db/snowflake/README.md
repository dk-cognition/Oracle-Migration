# Snowflake target

Snowflake-native artifacts produced by the Oracle 19c migration. Deploy in order
into `HARTFORD.CLAIMS`:

```
db/snowflake/
├── 01_schema.sql       -- tables, sequences, AUTOINCREMENT/DEFAULT keys (no tablespaces/indexes/CHECKs)
├── 02_procedures.sql   -- claims_pkg as standalone Snowflake Scripting procedures + SQL UDFs
├── 03_views.sql        -- views with ANSI joins, QUALIFY, CASE; mv_daily_paid
└── 05_etl_stage.sql    -- psv_format file format + claims_extract_stage for COPY INTO unloads
```

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent and remaining follow-ups.
