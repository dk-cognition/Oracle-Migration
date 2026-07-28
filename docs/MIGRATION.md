# Oracle 19c → Snowflake Migration Guide

This document catalogs every Oracle-specific construct in this repository and its
Snowflake equivalent. It is the working checklist for the migration demo.

> Scope: schema DDL, PL/SQL, reporting SQL, the Java JDBC data-access layer, and
> the nightly batch/ETL flow.

**Status: migration complete.** Every checklist item in section 9 is done; the
Snowflake artifacts live in `db/snowflake/` (mirroring the `db/oracle/`
filenames) and the Java/ETL/config layers now target Snowflake. Per-section
annotations below record where each construct landed.

---

## 1. Data types

**Done** — applied in `db/snowflake/01_schema.sql`: all `VARCHAR2(n CHAR|BYTE)` →
`VARCHAR(n)`, `risk_score` → `FLOAT`, every Oracle `DATE` → `TIMESTAMP_NTZ`
(time component preserved), `customer.notes` `CLOB` → `VARCHAR`.

| Oracle | Snowflake | Notes |
|--------|-----------|-------|
| `VARCHAR2(n CHAR)` / `VARCHAR2(n BYTE)` | `VARCHAR(n)` | Snowflake is always character-length; byte semantics disappear. |
| `NUMBER` (no precision) | `NUMBER(38,0)` or `FLOAT` | Decide per column; `risk_score` is fractional → `FLOAT`. |
| `NUMBER(p,s)` | `NUMBER(p,s)` | Direct. |
| `DATE` | `TIMESTAMP_NTZ` | **Oracle `DATE` carries a time component.** Mapping to Snowflake `DATE` silently drops the time — must use `TIMESTAMP`. |
| `CLOB` | `VARCHAR` (up to 16 MB) | Snowflake has no LOB type. |
| `RAW` / `BLOB` | `BINARY` | Not used here but common. |

## 2. Sequences & key generation

**Done** — `policy_id` is `AUTOINCREMENT(500000, 1)`; `customer_id`, `claim_id`
and `payment_id` default from `seq_customer_id` / `seq_claim_id` /
`seq_payment_id` (`CACHE`/`NOCACHE` dropped). `open_claim` still draws
`seq_claim_id.NEXTVAL` explicitly because it needs the id to build
`claim_number`. `CustomerDao.peekNextId()` selects `NEXTVAL` without `dual`.

- Oracle: `CREATE SEQUENCE`, `seq.NEXTVAL`, applied by a `BEFORE INSERT` trigger.
- Snowflake: use `CREATE SEQUENCE` + column `DEFAULT seq.NEXTVAL`, **or** an
  `IDENTITY`/`AUTOINCREMENT` column. Snowflake sequences are **not gap-free** and
  have no `CACHE`/`NOCACHE`, `CURRVAL`, or per-session `NEXTVAL` guarantees.
- `SELECT seq.NEXTVAL FROM dual` → `SELECT seq.NEXTVAL;` (no `DUAL` in Snowflake).

## 3. Triggers

**Done** — `trg_customer_biu` and `trg_policy_bi` are replaced by the column
defaults in `01_schema.sql`; the remaining "on update" behaviour is the
`str_customer_changes` stream + `tsk_customer_updated_ts` task in
`db/snowflake/02_packages.sql`, and `customer_upsert` sets `updated_ts` inline.
The MV needs no refresh trigger (Snowflake maintains it).

Snowflake has **no row-level triggers**. Re-express:
- `trg_customer_biu` (PK default + `updated_ts`) → column `DEFAULT`s
  (`AUTOINCREMENT`, `DEFAULT CURRENT_TIMESTAMP`). "On update" timestamp must be
  set by the writing statement or a Stream+Task.
- `trg_policy_bi` → `policy_id NUMBER AUTOINCREMENT`.
- MV fast-refresh trigger semantics → **Streams + Tasks**.

## 4. PL/SQL → Snowflake Scripting

**Done** — `db/snowflake/02_packages.sql`: `open_claim` and `post_payment` are
standalone Scripting procedures, `loss_ratio` and `fn_customer_full_name` are
scalar UDFs, `g_default_reserve` is the `app_config` row read by
`fn_default_reserve()`, `RAISE_APPLICATION_ERROR(-20001, ...)` is a declared
`EXCEPTION` + `RAISE`, and `post_payment` re-queries the claim instead of using
`RETURNING ... INTO`. Seed data migrated in `db/snowflake/04_seed_data.sql`.

`claims_pkg` (a package) has no direct analog — Snowflake has no packages.
- Split each program unit into its own `CREATE PROCEDURE` (SQL Scripting or
  JavaScript) / `CREATE FUNCTION`.
- Package constant `g_default_reserve` → a scalar UDF or a config table.
- `RAISE_APPLICATION_ERROR` → Scripting `RAISE`/`EXCEPTION`.
- `RETURNING ... INTO` is not supported → re-query or use a Stream.
- Implicit `COMMIT` inside procedures differs; review transaction boundaries.

## 5. SQL construct rewrites

**Done** — applied in `db/snowflake/03_views.sql` and
`src/main/resources/sql/reports.sql`: `(+)` → `LEFT JOIN`, `ROWNUM` →
`QUALIFY ROW_NUMBER()` (views) / `LIMIT` (reports), `CONNECT BY` +
`SYS_CONNECT_BY_PATH` + `LEVEL` → `WITH RECURSIVE` (also exposed as
`vw_agent_org_chart`), `DECODE` → `CASE`, `NVL` → `COALESCE`, `NVL2` → `IFF`,
`SYSDATE` → `CURRENT_TIMESTAMP()`, `ADD_MONTHS` → `DATEADD`, day arithmetic →
`DATEDIFF`, `TO_CHAR` → `TO_VARCHAR`, and `MERGE ... FROM dual` → `MERGE` over a
cast, `dual`-free source.

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

**Done** — `CREATE TABLESPACE` and every `TABLESPACE` clause removed, all four
`CREATE INDEX` statements dropped (including the function-based
`ix_cust_upper_name`), and `mv_daily_paid` created without
`BUILD IMMEDIATE`/`REFRESH FAST ON COMMIT`. Oracle `CHECK` constraints are also
gone: Snowflake does not enforce them, so status values are validated in the
application / procedure layer.

- `CREATE TABLESPACE`, `TABLESPACE ...` clauses — Snowflake is storage-managed.
- Function-based index `ix_cust_upper_name` — Snowflake has **no user indexes**;
  rely on micro-partitions / clustering keys if needed.
- All other `CREATE INDEX` statements — remove.
- Materialized view with joins (`mv_daily_paid` is fine — single table — but
  `REFRESH FAST ON COMMIT` → Snowflake MVs auto-maintain; drop the clause).

## 7. Java / JDBC layer

**Done** — `pom.xml` swaps `ojdbc11` for `snowflake-jdbc`; `DataSourceFactory`
drops the `oracle.net.tns_admin` property and the
`implicitStatementCacheSize`/`defaultRowPrefetch` pool props, passes
warehouse/db/schema/role as driver properties and reads
`SNOWFLAKE_APP_PASSWORD`; `src/main/resources/tnsnames.ora` is deleted;
`ClaimDao` calls `CALL proc(?, ...)` / `SELECT udf(?)` instead of
`CallableStatement` OUT parameters; `CustomerDao.insert` re-queries for the
generated id instead of `getGeneratedKeys()`.

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

**Done** — `NightlyExtract.unloadChangedClaims()` runs
`COPY INTO @hartford.claims.claims_stage/...` (Parquet) instead of writing a PSV
file, and `scripts/export_oracle_to_stage.sh` became
`scripts/export_to_snowflake_stage.sh`, which creates the stage, file format and
`pipe_claims_ingest` Snowpipe and unloads each table. `TRUNC(SYSDATE) - 1` is now
`DATEADD('day', -1, CURRENT_DATE())`.

- `NightlyExtract` + `export_oracle_to_stage.sh` produce pipe-delimited flat
  files SFTP'd to the warehouse. Replace with `COPY INTO @stage` /
  **Snowpipe** for continuous load, eliminating the flat-file hop.
- `TRUNC(SYSDATE) - 1` window logic → `DATEADD` / Streams for CDC.

## 9. Suggested migration order (demo script)

- [x] 1. Translate DDL (`db/oracle/01_schema.sql` → `db/snowflake/01_schema.sql`).
- [x] 2. Rewrite views (`03_views.sql`) — removed `(+)` and `ROWNUM`.
- [x] 3. Re-implement `claims_pkg` as Snowflake procedures/UDFs
      (`db/snowflake/02_packages.sql`), plus seed data
      (`db/snowflake/04_seed_data.sql`).
- [x] 4. Convert reporting SQL in `src/main/resources/sql/reports.sql`.
- [x] 5. Swap the JDBC driver/config and rework the `CallableStatement` and
      generated-key logic (`pom.xml`, `DataSourceFactory`, `ClaimDao`,
      `CustomerDao`, `tnsnames.ora` deleted).
- [x] 6. Replace the flat-file ETL with `COPY INTO`/Snowpipe
      (`NightlyExtract`, `scripts/export_to_snowflake_stage.sh`).
- [x] 7. Re-point `application.properties` to the Snowflake datasource block.

`mvn -q compile` and `mvn -q test` pass after the Java changes (no live database
required). `SqlLibraryTest.orgChartQueryUsesConnectBy` was retargeted to
`orgChartQueryUsesRecursiveCte`, since the assertion pinned the migrated-away
Oracle syntax.

## 10. Follow-ups not covered by this migration

- Snowflake does not enforce `PRIMARY KEY`, `UNIQUE`, `FOREIGN KEY` or `CHECK`
  constraints; they remain in the DDL for documentation/tooling only. Uniqueness
  of `claim_number` is pre-checked inside `open_claim`.
- `tsk_customer_updated_ts` needs a running `CLAIMS_WH` warehouse and the
  `EXECUTE TASK` privilege before `ALTER TASK ... RESUME` succeeds.
- The Snowpipe uses an internal stage, so it is triggered through the Snowpipe
  REST API; point the stage at S3/GCS/Azure to use `AUTO_INGEST`.
