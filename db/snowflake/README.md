# Snowflake target

Snowflake-native artifacts produced by the Oracle → Snowflake migration. Run in
order against an account where you can create `HARTFORD.CLAIMS`:

```
db/snowflake/
├── 01_schema.sql       -- tables, sequences, AUTOINCREMENT/DEFAULT keys (no tablespaces/indexes)
├── 02_procedures.sql   -- claims_pkg as open_claim / post_payment procs + loss_ratio, fn_customer_full_name UDFs
├── 03_views.sql        -- views with ANSI joins, CASE, LIMIT, recursive-CTE org chart, mv_daily_paid
├── 04_seed_data.sql    -- seed data (TIMESTAMP_NTZ literals, claims opened via open_claim)
└── 05_etl_stage.sql    -- file format + stage for COPY INTO unloads, Snowpipe template
```

See [`../../docs/MIGRATION.md`](../../docs/MIGRATION.md) for the mapping from
each Oracle construct to its Snowflake equivalent and the cutover notes.
