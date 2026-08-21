# Hartford Claims Data Store

> **Demo repository.** Fictional Property & Casualty (P&C) policy administration
> and claims-processing data store for *The Hartford*, **migrated from Oracle 19c
> to Snowflake**. The Oracle sources are kept under `db/oracle/` as the
> source-system reference. All data, hostnames, and identifiers are synthetic.

## What this system does

A small insurance back-office data layer:

- **Customers** hold one or more **policies** (auto, home, umbrella, workers' comp).
- Policies are sold by **agents** arranged in a management hierarchy.
- **Claims** are booked against policies and paid out via **claim payments**.
- A Java data-access layer + nightly batch feed a downstream warehouse.

## What the migration covered

The Oracle sources are deliberately packed with constructs that do **not** port
1:1 to Snowflake — all of them have been rewritten (see
[`docs/MIGRATION.md`](docs/MIGRATION.md) section 9 for the status list):

- `DATE`-with-time semantics, unbounded `NUMBER`, `VARCHAR2(n CHAR/BYTE)`, `CLOB`
- Sequences + `.NEXTVAL` driven by `BEFORE INSERT` **triggers**
- A **PL/SQL package** (`claims_pkg`) with functions/procedures called over JDBC
- Legacy `(+)` outer joins, `ROWNUM` paging, `CONNECT BY` hierarchy, `DECODE`,
  `NVL`/`NVL2`, `SYSDATE`, `ADD_MONTHS`, `TO_CHAR`, `... FROM dual`, `MERGE`
- Tablespaces and a function-based index
- A flat-file **ETL** (SQL\*Plus spool → SFTP) instead of `COPY INTO`/Snowpipe
- An Oracle-thin JDBC config with `tnsnames.ora` and vendor-specific pool props

See [`docs/MIGRATION.md`](docs/MIGRATION.md) for the full construct-by-construct
Oracle→Snowflake mapping and the migration status.

## Layout

```
db/oracle/            Oracle 19c DDL, PL/SQL, views, seed data (source-system reference)
db/snowflake/         Snowflake DDL, procedures, views, streams/tasks, ingest, seed data
src/main/java/        Java 11 JDBC data-access layer, reports, COPY INTO unload job
src/main/resources/   application.properties, externalized SQL
src/test/java/        Unit tests (no live DB required)
scripts/              COPY INTO / Snowpipe load driver
docs/MIGRATION.md     Oracle → Snowflake migration guide / checklist
```

### Key files

| File | Role |
|------|------|
| `db/snowflake/01_schema.sql` | Tables, sequences, clustering keys, `claims_config` |
| `db/snowflake/02_procedures.sql` | `claims_pkg` as Scripting procedures + UDFs |
| `db/snowflake/03_views.sql` | Views with ANSI joins, `QUALIFY`, `WITH RECURSIVE` |
| `db/snowflake/04_streams_tasks.sql` | Trigger logic as Streams + Tasks |
| `db/snowflake/05_ingest.sql` | Stage, file format, `COPY INTO`, Snowpipes |
| `src/main/resources/sql/reports.sql` | Named reporting queries (Snowflake SQL) |
| `src/.../dao/ClaimDao.java` | Calls the Snowflake procedures/UDFs |
| `src/.../etl/NightlyExtract.java` | `COPY INTO @claims_stage` unload off the CDC stream |

## Build

```bash
mvn -q compile          # compiles the Java data-access layer
mvn -q test             # runs unit tests (no database needed)
```

Runtime execution needs a reachable Snowflake account (configured in
`src/main/resources/application.properties`) and the `SNOWFLAKE_APP_PASSWORD`
environment variable — neither is required to build or run the unit tests.
