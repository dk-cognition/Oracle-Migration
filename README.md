# Hartford Claims Data Store

> **Demo repository.** Fictional Property & Casualty (P&C) policy administration
> and claims-processing data store for *The Hartford*, now backed by
> **Snowflake** (migrated from **Oracle 19c**). All data, hostnames, and
> identifiers are synthetic.

## What this system does

A small insurance back-office data layer:

- **Customers** hold one or more **policies** (auto, home, umbrella, workers' comp).
- Policies are sold by **agents** arranged in a management hierarchy.
- **Claims** are booked against policies and paid out via **claim payments**.
- A Java data-access layer + nightly batch feed a downstream warehouse.

## What the migration changed

The Oracle-specific constructs the system was built on have Snowflake-native
replacements:

- `TIMESTAMP_NTZ` for time-bearing `DATE`s, sized `NUMBER`/`FLOAT`, `VARCHAR`
  for `VARCHAR2`/`CLOB`
- Sequence-backed column `DEFAULT`s instead of `BEFORE INSERT` triggers, with a
  Stream+Task for the "on update" timestamp
- `claims_pkg` split into standalone Snowflake Scripting procedures and UDFs
- ANSI `LEFT JOIN`, `QUALIFY`, `WITH RECURSIVE`, `CASE`, `COALESCE`, `IFF`,
  `DATEADD`/`DATEDIFF`, `TO_VARCHAR`, `MERGE` without `dual`
- No tablespaces or indexes (micro-partitions; clustering only if justified)
- `COPY INTO @stage` + Snowpipe in place of the SQL\*Plus spool → SFTP hop
- Snowflake JDBC driver and account URL; no `tnsnames.ora`

See [`docs/MIGRATION.md`](docs/MIGRATION.md) for the construct-by-construct
mapping, the script apply order, and the environment values still to be filled
in per account.

## Layout

```
db/oracle/            Oracle 19c DDL, PL/SQL, views, seed data (the retired source system)
db/snowflake/         Snowflake DDL, procedures, views, streams/tasks, stages
src/main/java/        Java 11 JDBC data-access layer, reports, nightly unload
src/main/resources/   application.properties, externalized SQL
src/test/java/        Unit tests (no live DB required)
scripts/              COPY INTO unload to the Snowflake stage
docs/MIGRATION.md     Oracle → Snowflake migration guide / checklist
```

### Key files

| File | Role |
|------|------|
| `db/snowflake/01_schema.sql` | Tables, sequences, constraints |
| `db/snowflake/02_procedures.sql` | `open_claim`, `post_payment`, `loss_ratio`, UDFs |
| `db/snowflake/03_views.sql` | Reporting views + materialized view |
| `db/snowflake/04_streams_tasks.sql` | Trigger replacements + claim CDC |
| `db/snowflake/05_stages_snowpipe.sql` | Stage, file format, auto-ingest pipe |
| `src/main/resources/sql/reports.sql` | Named reporting queries (Snowflake dialect) |
| `src/.../dao/ClaimDao.java` | Calls the Snowflake procedures via `CALL` |
| `src/.../etl/NightlyExtract.java` | `COPY INTO @stage` nightly unload |

## Build

```bash
mvn -q compile          # compiles the Java data-access layer
mvn -q test             # runs unit tests (no database needed)
```

Runtime execution needs a reachable Snowflake account (the URL in
`application.properties`) and the `SNOWFLAKE_APP_PASSWORD` environment variable —
not required for the build or the unit tests.
