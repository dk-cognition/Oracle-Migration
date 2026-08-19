# Oracle 19c → Snowflake Migration Guide

This document catalogs every Oracle-specific construct in this repository and its
Snowflake equivalent. It is the working checklist for the migration demo.

> Scope: schema DDL, PL/SQL, reporting SQL, the Java JDBC data-access layer, and
> the nightly batch/ETL flow.

**Migration status: complete.** Every construct below has been migrated; each
section is annotated with where the Snowflake version lives. The `db/oracle/`
tree is retained as the source-of-record for the original system.

| Area | Oracle source | Snowflake target | Status |
|------|---------------|------------------|--------|
| Schema DDL | `db/oracle/01_schema.sql` | `db/snowflake/01_schema.sql` | ✅ |
| Views + MV | `db/oracle/03_views.sql` | `db/snowflake/03_views.sql` | ✅ |
| PL/SQL package | `db/oracle/02_packages.sql` | `db/snowflake/02_procedures.sql` | ✅ |
| Triggers | `db/oracle/02_packages.sql` | column defaults + `db/snowflake/04_streams_tasks.sql` | ✅ |
| Reporting SQL | `src/main/resources/sql/reports.sql` | same file, Snowflake dialect | ✅ |
| JDBC layer | `DataSourceFactory`, `ClaimDao`, `CustomerDao`, `pom.xml` | Snowflake driver + `CALL` semantics | ✅ |
| ETL / batch | `NightlyExtract`, `scripts/export_oracle_to_stage.sh` | `COPY INTO`/Snowpipe (`db/snowflake/05_stages_snowpipe.sql`, `scripts/unload_to_snowflake_stage.sh`) | ✅ |
| Datasource config | `application.properties` (Oracle block), `tnsnames.ora` | Snowflake block active, TNS file deleted | ✅ |

---

## 1. Data types

✅ Applied in `db/snowflake/01_schema.sql`: all `VARCHAR2(n CHAR/BYTE)` →
`VARCHAR(n)`; `risk_score` → `FLOAT`; every time-bearing `DATE` (`created_ts`,
`updated_ts`, `reported_date`, `payment_date`, `loss_date`, `effective_date`,
`expiration_date`) → `TIMESTAMP_NTZ`; `date_of_birth`/`hire_date` stay `DATE`
(no time component); `notes CLOB` → `VARCHAR`.

| Oracle | Snowflake | Notes |
|--------|-----------|-------|
| `VARCHAR2(n CHAR)` / `VARCHAR2(n BYTE)` | `VARCHAR(n)` | Snowflake is always character-length; byte semantics disappear. |
| `NUMBER` (no precision) | `NUMBER(38,0)` or `FLOAT` | Decide per column; `risk_score` is fractional → `FLOAT`. |
| `NUMBER(p,s)` | `NUMBER(p,s)` | Direct. |
| `DATE` | `TIMESTAMP_NTZ` | **Oracle `DATE` carries a time component.** Mapping to Snowflake `DATE` silently drops the time — must use `TIMESTAMP`. |
| `CLOB` | `VARCHAR` (up to 16 MB) | Snowflake has no LOB type. |
| `RAW` / `BLOB` | `BINARY` | Not used here but common. |

## 2. Sequences & key generation

✅ Applied: the four sequences are recreated without `CACHE`/`NOCACHE` and wired
as `DEFAULT seq.NEXTVAL` on `customer_id`, `policy_id`, `claim_id`, and
`payment_id`. `CustomerDao` now draws `NEXTVAL` explicitly (no `DUAL`, no
`CURRVAL`, no `getGeneratedKeys()`).

- Oracle: `CREATE SEQUENCE`, `seq.NEXTVAL`, applied by a `BEFORE INSERT` trigger.
- Snowflake: use `CREATE SEQUENCE` + column `DEFAULT seq.NEXTVAL`, **or** an
  `IDENTITY`/`AUTOINCREMENT` column. Snowflake sequences are **not gap-free** and
  have no `CACHE`/`NOCACHE`, `CURRVAL`, or per-session `NEXTVAL` guarantees.
- `SELECT seq.NEXTVAL FROM dual` → `SELECT seq.NEXTVAL;` (no `DUAL` in Snowflake).

## 3. Triggers

✅ Applied: `trg_policy_bi` and the insert half of `trg_customer_biu` are column
defaults in `01_schema.sql`; the "on update" `updated_ts` is maintained by
`strm_customer_dml` + `tsk_customer_updated_ts` in `04_streams_tasks.sql`
(the `customer_upsert` MERGE also sets it directly).

Snowflake has **no row-level triggers**. Re-express:
- `trg_customer_biu` (PK default + `updated_ts`) → column `DEFAULT`s
  (`AUTOINCREMENT`, `DEFAULT CURRENT_TIMESTAMP`). "On update" timestamp must be
  set by the writing statement or a Stream+Task.
- `trg_policy_bi` → `policy_id NUMBER AUTOINCREMENT`.
- MV fast-refresh trigger semantics → **Streams + Tasks**.

## 4. PL/SQL → Snowflake Scripting

✅ Applied in `db/snowflake/02_procedures.sql`: `open_claim`, `post_payment`, and
`loss_ratio` are standalone Snowflake Scripting objects; `g_default_reserve` is
the `fn_default_reserve()` UDF; `fn_customer_full_name` is a SQL UDF;
`RAISE_APPLICATION_ERROR` became declared exceptions + `RAISE`; `RETURNING ...
INTO` became a re-query; `post_payment` brackets its writes in an explicit
`BEGIN TRANSACTION`/`COMMIT` with rollback on error. `loss_ratio` stayed a
procedure rather than a UDF because scalar SQL UDFs that read tables cannot be
used freely inside other queries.

`claims_pkg` (a package) has no direct analog — Snowflake has no packages.
- Split each program unit into its own `CREATE PROCEDURE` (SQL Scripting or
  JavaScript) / `CREATE FUNCTION`.
- Package constant `g_default_reserve` → a scalar UDF or a config table.
- `RAISE_APPLICATION_ERROR` → Scripting `RAISE`/`EXCEPTION`.
- `RETURNING ... INTO` is not supported → re-query or use a Stream.
- Implicit `COMMIT` inside procedures differs; review transaction boundaries.

## 5. SQL construct rewrites

✅ Applied across `db/snowflake/03_views.sql` and
`src/main/resources/sql/reports.sql` (which keeps the `-- name: <id>` delimiters
the Java `SqlLibrary` loader relies on). Notable calls:
`REGEXP_LIKE` implicitly anchors the whole value in Snowflake, so Oracle's
`'^860-'` prefix match became `'860-.*'`; `agent_org_chart` builds `depth` and
`path` inside the recursive CTE and orders by `path` in place of
`ORDER SIBLINGS BY`.

| Oracle | Snowflake |
|--------|-----------|
| `a.id = b.id (+)` (legacy outer join) | `LEFT JOIN b ON a.id = b.id` |
| `ROWNUM <= 10` | `QUALIFY ROW_NUMBER() OVER (ORDER BY ...) <= 10` or `LIMIT 10` |
| `CONNECT BY PRIOR ... START WITH ...` | `WITH RECURSIVE cte AS (...)` |
| `SYS_CONNECT_BY_PATH(col, sep)` | build path inside the recursive CTE |
| `LEVEL` | depth counter in the recursive CTE |
| `DECODE(x, a, r1, b, r2, def)` | `DECODE` **is supported**, but prefer `CASE` |
| `NVL(x, y)` | `COALESCE(x, y)` (or `NVL`, also supported) |
| `NVL2(x, a, b)` | `IFF(x IS NOT NULL, a, b)` |
| `SYSDATE` | `CURRENT_TIMESTAMP()` |
| `TRUNC(SYSDATE)` | `CURRENT_DATE()` / `DATE_TRUNC('DAY', ...)` |
| `ADD_MONTHS(d, n)` | `DATEADD('month', n, d)` |
| `SYSDATE - reported_date` (day diff) | `DATEDIFF('day', reported_date, CURRENT_TIMESTAMP())` |
| `TO_CHAR(d, 'YYYY-MM')` | `TO_VARCHAR(d, 'YYYY-MM')` |
| `REGEXP_LIKE(c, p)` | `REGEXP_LIKE(c, p)` (supported; anchoring differs) |
| `... FROM dual` | drop the `FROM dual` |
| `MERGE ... USING (SELECT ... FROM dual)` | `MERGE ... USING (SELECT ... ) src` |

## 6. Physical / storage DDL to drop

✅ Applied: no `CREATE TABLESPACE`/`TABLESPACE` clauses and no `CREATE INDEX`
statements remain (including the function-based `ix_cust_upper_name`).
PK/FK/UNIQUE/CHECK constraints are preserved — note Snowflake does not enforce
them, which is why `open_claim` checks for a duplicate `claim_number` itself.
A candidate `CLUSTER BY (policy_id, status)` on `claim` is documented but left
commented: not justified at current volumes.

- `CREATE TABLESPACE`, `TABLESPACE ...` clauses — Snowflake is storage-managed.
- Function-based index `ix_cust_upper_name` — Snowflake has **no user indexes**;
  rely on micro-partitions / clustering keys if needed.
- All other `CREATE INDEX` statements — remove.
- Materialized view with joins (`mv_daily_paid` is fine — single table — but
  `REFRESH FAST ON COMMIT` → Snowflake MVs auto-maintain; drop the clause).

## 7. Java / JDBC layer

✅ Applied: `pom.xml` now depends on `net.snowflake:snowflake-jdbc`;
`DataSourceFactory` sets the Snowflake driver/URL (warehouse, db, schema and
role in the URL, so no `connectionInitSql`), drops the TNS system property and
the Oracle-only pool props, and reads the password from
`SNOWFLAKE_APP_PASSWORD`. `ClaimDao` uses `CALL proc(...)` and reads the return
value from the result set instead of `{ ? = call ... }` OUT parameters.
`src/main/resources/tnsnames.ora` is deleted.

| Concern | Oracle today | Snowflake target |
|---------|--------------|------------------|
| Driver | `oracle.jdbc.OracleDriver` (`ojdbc11`) | `net.snowflake.client.jdbc.SnowflakeDriver` (`snowflake-jdbc`) |
| URL | `jdbc:oracle:thin:@HRTFD_PROD` + `tnsnames.ora` | `jdbc:snowflake://<account>.snowflakecomputing.com/?warehouse=...&db=...&role=...` |
| TNS | `oracle.net.tns_admin` system property, `tnsnames.ora` | none (delete the file) |
| Pool init SQL | `ALTER SESSION SET CURRENT_SCHEMA` | `USE SCHEMA` / set in URL |
| Vendor props | `implicitStatementCacheSize`, `defaultRowPrefetch` | remove (Snowflake-managed) |
| Stored-proc calls | `CallableStatement` `{ ? = call pkg.fn(...) }` | rework: Snowflake procs return one value; often push logic to app/dbt |
| Generated keys | `getGeneratedKeys()` via ROWID | not supported; `SELECT seq.CURRVAL` won't work either — re-query or use `RETURNING` in Snowpark |

Files to touch: `DataSourceFactory`, `ClaimDao` (all `CallableStatement` calls),
`CustomerDao.insert`/`peekNextId`, and every statement string in `reports.sql`.

## 8. ETL / batch

✅ Applied: `NightlyExtract` runs `COPY INTO @claims_stage` over the CDC feed
drained from `strm_claim_changes` (with a `DATEADD` window kept only as a
backfill path), `db/snowflake/05_stages_snowpipe.sql` defines the stage, file
format and auto-ingest pipe, and `scripts/export_oracle_to_stage.sh` is replaced
by `scripts/unload_to_snowflake_stage.sh`. No flat file or SFTP hop remains.

- `NightlyExtract` + `export_oracle_to_stage.sh` produce pipe-delimited flat
  files SFTP'd to the warehouse. Replace with `COPY INTO @stage` /
  **Snowpipe** for continuous load, eliminating the flat-file hop.
- `TRUNC(SYSDATE) - 1` window logic → `DATEADD` / Streams for CDC.

## 9. Migration order (all steps done)

1. ✅ Translate DDL (`db/oracle/01_schema.sql` → `db/snowflake/01_schema.sql`).
2. ✅ Rewrite views (`03_views.sql`) — `(+)` and `ROWNUM` removed.
3. ✅ Re-implement `claims_pkg` as Snowflake procedures/UDFs
   (`db/snowflake/02_procedures.sql`) plus `04_streams_tasks.sql` for triggers.
4. ✅ Convert reporting SQL in `src/main/resources/sql/reports.sql`.
5. ✅ Swap the JDBC driver/config and rework the `CallableStatement` calls.
6. ✅ Replace the flat-file ETL with `COPY INTO`/Snowpipe.
7. ✅ Re-point `application.properties` at the Snowflake datasource block.

## 10. Deployment order & remaining operational work

Apply the Snowflake scripts in this order:
`01_schema.sql` → `02_procedures.sql` → `03_views.sql` →
`04_streams_tasks.sql` → `05_stages_snowpipe.sql`.

Environment-specific values still to be supplied by whoever runs the migration:

- The account identifier in `db.url` and the `CLAIMS_WH` warehouse name.
- `SNOWFLAKE_APP_PASSWORD` for the `HARTFORD_APP` user (replaces
  `ORACLE_APP_PASSWORD`).
- The stage `URL` and `STORAGE_INTEGRATION` in `05_stages_snowpipe.sql`, and the
  cloud notification wiring for `pipe_claim_inbound` auto-ingest.
- A one-time historical data load (`db/oracle/04_seed_data.sql` has no Snowflake
  counterpart; production data moves via bulk unload → `COPY INTO`).
