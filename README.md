# Hartford Claims Data Store

> **Demo repository.** Fictional Property & Casualty (P&C) policy administration
> and claims-processing data store for *The Hartford*. The Oracle 19c source
> system lives in `db/oracle/`; the application and the data store have been
> **migrated to Snowflake** (`db/snowflake/`). All data, hostnames, and
> identifiers are synthetic.

## What this system does

A small insurance back-office data layer:

- **Customers** hold one or more **policies** (auto, home, umbrella, workers' comp).
- Policies are sold by **agents** arranged in a management hierarchy.
- **Claims** are booked against policies and paid out via **claim payments**.
- A Java data-access layer + nightly batch feed a downstream warehouse.

## Why it's a good migration target

The codebase is deliberately packed with Oracle-specific constructs that do **not**
port 1:1 to Snowflake — the exact things a real migration has to find and rewrite:

- `DATE`-with-time semantics, unbounded `NUMBER`, `VARCHAR2(n CHAR/BYTE)`, `CLOB`
- Sequences + `.NEXTVAL` driven by `BEFORE INSERT` **triggers**
- A **PL/SQL package** (`claims_pkg`) with functions/procedures called over JDBC
- Legacy `(+)` outer joins, `ROWNUM` paging, `CONNECT BY` hierarchy, `DECODE`,
  `NVL`/`NVL2`, `SYSDATE`, `ADD_MONTHS`, `TO_CHAR`, `... FROM dual`, `MERGE`
- Tablespaces and a function-based index
- A flat-file **ETL** (SQL\*Plus spool → SFTP) instead of `COPY INTO`/Snowpipe
- An Oracle-thin JDBC config with `tnsnames.ora` and vendor-specific pool props

The migrated Snowflake artifacts sit beside each source file, so every rewrite is
diffable against its Oracle original.

See [`docs/MIGRATION.md`](docs/MIGRATION.md) for the full construct-by-construct
Oracle→Snowflake mapping and a suggested migration order.

## Layout

```
db/oracle/            Oracle 19c DDL, PL/SQL, views, seed data (the source system)
db/snowflake/         Migrated Snowflake DDL, procedures, views, seed data
src/main/java/        Java 11 JDBC data-access layer, reports, nightly ETL
src/main/resources/   application.properties, externalized Snowflake SQL
src/test/java/        Unit tests (no live DB required)
scripts/              COPY INTO / Snowpipe stage publish
docs/MIGRATION.md     Oracle → Snowflake migration guide / checklist
```

### Key files

| File | Role |
|------|------|
| `db/oracle/01_schema.sql` | Tables, sequences, constraints, indexes, tablespace |
| `db/oracle/02_packages.sql` | `claims_pkg` package + functions + triggers |
| `db/oracle/03_views.sql` | Reporting views (`(+)`, `ROWNUM`, `DECODE`) + MV |
| `db/snowflake/*.sql` | The migrated Snowflake schema, procedures, views, seed |
| `src/main/resources/sql/reports.sql` | Named reporting queries (Snowflake SQL) |
| `src/.../dao/ClaimDao.java` | Calls the Snowflake procedures/UDFs over JDBC |
| `src/.../etl/NightlyExtract.java` | `COPY INTO @stage` nightly unload |

## Build

```bash
mvn -q compile          # compiles the Java data-access layer
mvn -q test             # runs unit tests (no database needed)
```

Runtime execution needs a reachable Snowflake account (see the `db.*` block in
`src/main/resources/application.properties`) and the `SNOWFLAKE_APP_PASSWORD`
environment variable — not required for the migration demo, which works
statically over the SQL and Java sources.

## Running the migration demo with Devin

Point Devin at this repo and ask it to migrate a slice, e.g.:

> "Migrate `db/oracle/03_views.sql` to Snowflake, writing the result to
> `db/snowflake/03_views.sql`, and update `docs/MIGRATION.md`."

or

> "Swap the JDBC layer from Oracle to Snowflake and rewrite the queries in
> `reports.sql`."
