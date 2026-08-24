# Hartford Claims Data Store

> **Demo repository.** Fictional Property & Casualty (P&C) policy administration
> and claims-processing data store for *The Hartford*, now backed by
> **Snowflake**. It showcases an **Oracle → Snowflake migration** with Devin.
> All data, hostnames, and identifiers are synthetic.

## What this system does

A small insurance back-office data layer:

- **Customers** hold one or more **policies** (auto, home, umbrella, workers' comp).
- Policies are sold by **agents** arranged in a management hierarchy.
- **Claims** are booked against policies and paid out via **claim payments**.
- A Java data-access layer + nightly batch feed a downstream warehouse.

## What this migration demonstrates

The repository includes a complete source-to-target migration. The source
artifacts remain under `db/oracle`; the active implementation uses Snowflake
syntax and cloud-native operations:

- Snowflake-native types, sequences, identity columns, and metadata constraints
- Standalone Snowflake Scripting procedures and SQL UDFs
- ANSI joins, recursive CTEs, and window-function filtering
- Cloud-stage unload/load with `COPY INTO` and Snowpipe
- Snowflake JDBC configuration with warehouse, database, schema, and role

See [`docs/MIGRATION.md`](docs/MIGRATION.md) for the full
Oracle-to-Snowflake mapping and migration status.

## Layout

```
db/oracle/            Oracle 19c DDL, PL/SQL, views, seed data (source system)
db/snowflake/         Snowflake DDL, routines, views, tasks, and stages
src/main/java/        Java 11 JDBC data-access layer, reports, nightly ETL
src/main/resources/   application.properties and externalized SQL
src/test/java/        Unit tests (no live DB required)
scripts/              SnowSQL stage load script
docs/MIGRATION.md     Oracle → Snowflake migration guide / checklist
```

### Key files

| File | Role |
|------|------|
| `db/oracle/01_schema.sql` | Source tables, sequences, constraints, and indexes |
| `db/oracle/02_packages.sql` | Source package, functions, and triggers |
| `db/oracle/03_views.sql` | Source reporting views and materialized view |
| `src/main/resources/sql/reports.sql` | Named Snowflake reporting queries |
| `src/.../dao/ClaimDao.java` | Calls Snowflake procedures and UDFs |
| `src/.../etl/NightlyExtract.java` | Cloud-stage nightly unload |

## Build

```bash
mvn -q compile          # compiles the Java data-access layer
mvn -q test             # runs unit tests (no database needed)
```

Runtime execution needs a live Snowflake account configured in
`application.properties` and the `SNOWFLAKE_APP_PASSWORD` environment variable.
The migration demo itself works statically over the SQL and Java sources.

## Exploring the migration with Devin

Point Devin at this repo and ask it to review or extend a migrated slice, e.g.:

> "Review `db/snowflake/03_views.sql` against the source mapping in
> `docs/MIGRATION.md` and suggest any improvements."

or

> "Add a Snowflake-native report to `reports.sql` and its focused test."
