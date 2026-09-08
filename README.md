# Hartford Claims Data Store

> **Demo repository.** Fictional Property & Casualty (P&C) policy administration
> and claims-processing data store for *The Hartford*, originally backed by
> **Oracle 19c** and now migrated to **Snowflake**. It exists to showcase an
> **Oracle → Snowflake migration** with Devin. All data, hostnames, and
> identifiers are synthetic.

## What this system does

A small insurance back-office data layer:

- **Customers** hold one or more **policies** (auto, home, umbrella, workers' comp).
- Policies are sold by **agents** arranged in a management hierarchy.
- **Claims** are booked against policies and paid out via **claim payments**.
- A Java data-access layer + nightly batch feed a downstream warehouse.

## Why it's a good migration target

The Oracle source (`db/oracle/`) is deliberately packed with Oracle-specific
constructs that do **not** port 1:1 to Snowflake — the exact things the migration
had to find and rewrite:

- `DATE`-with-time semantics, unbounded `NUMBER`, `VARCHAR2(n CHAR/BYTE)`, `CLOB`
- Sequences + `.NEXTVAL` driven by `BEFORE INSERT` **triggers**
- A **PL/SQL package** (`claims_pkg`) with functions/procedures called over JDBC
- Legacy `(+)` outer joins, `ROWNUM` paging, `CONNECT BY` hierarchy, `DECODE`,
  `NVL`/`NVL2`, `SYSDATE`, `ADD_MONTHS`, `TO_CHAR`, `... FROM dual`, `MERGE`
- Tablespaces and a function-based index
- A flat-file **ETL** (SQL\*Plus spool → SFTP) instead of `COPY INTO`/Snowpipe
- An Oracle-thin JDBC config with `tnsnames.ora` and vendor-specific pool props

See [`docs/MIGRATION.md`](docs/MIGRATION.md) for the full construct-by-construct
Oracle→Snowflake mapping and the completed checklist.

## Layout

```
db/oracle/            Oracle 19c DDL, PL/SQL, views, seed data (the legacy source system)
db/snowflake/         Snowflake DDL, procedures, views, streams/tasks, stages/pipe, seed data
src/main/java/        Java 11 JDBC data-access layer (Snowflake driver), reports, nightly unload
src/main/resources/   application.properties, externalized Snowflake SQL
src/test/java/        Unit tests (no live DB required)
scripts/              One-time COPY INTO cut-over load from the inbound stage
docs/MIGRATION.md     Oracle → Snowflake migration guide / checklist
```

### Key files

| File | Role |
|------|------|
| `db/oracle/*.sql` | Legacy Oracle schema, `claims_pkg`, views (reference only) |
| `db/snowflake/01_schema.sql` | Snowflake tables + sequences as column defaults |
| `db/snowflake/02_procedures.sql` | `claims_pkg` as Snowflake Scripting procedures / SQL UDFs |
| `db/snowflake/03_views.sql` | Reporting views (`LEFT JOIN`, `QUALIFY`, `CASE`) + MV |
| `db/snowflake/04_streams_tasks.sql` | Trigger logic as Streams + Tasks |
| `db/snowflake/05_stage_pipe.sql` | Stages, file format, `COPY INTO`, Snowpipe |
| `src/main/resources/sql/reports.sql` | Named reporting queries (Snowflake dialect) |
| `src/.../dao/ClaimDao.java` | `CALL`s the Snowflake procedures / UDFs |
| `src/.../etl/NightlyExtract.java` | Nightly `COPY INTO @claims_export` unload |

## Build

```bash
mvn -q compile          # compiles the Java data-access layer
mvn -q test             # runs unit tests (no database needed)
```

Runtime execution needs a live Snowflake account (`HARTFORD.CLAIMS`, warehouse
`CLAIMS_WH`) and the `SNOWFLAKE_APP_PASSWORD` environment variable — not required
for the migration demo, which works statically over the SQL and Java sources.

## Deploying the Snowflake objects

Run `db/snowflake/*.sql` in numeric order, then (once) upload the final Oracle
extracts to `@claims_stage` and run `scripts/load_stage_to_snowflake.sh`.
