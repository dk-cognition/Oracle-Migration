# Oracle 19c → Snowflake Migration Guide

This document catalogs every Oracle-specific construct in this repository and its
Snowflake equivalent. It is the working checklist for the migration demo.

**Status: migration complete.** The Snowflake artifacts live in `db/snowflake/`
(run in numeric order); the Java layer, `reports.sql`, `pom.xml`, and
`application.properties` target Snowflake. The Oracle sources in `db/oracle/` are
kept as the reference for the mapping below. Section 10 is the completed checklist.

> Scope: schema DDL, PL/SQL, reporting SQL, the Java JDBC data-access layer, and
> the nightly batch/ETL flow.

---

## 1. Data types

| Oracle | Snowflake | Notes |
|--------|-----------|-------|
| `VARCHAR2(n CHAR)` / `VARCHAR2(n BYTE)` | `VARCHAR(n)` | Snowflake is always character-length; byte semantics disappear. |
| `NUMBER` (no precision) | `NUMBER(38,0)` or `FLOAT` | Decide per column; `risk_score` is fractional → `FLOAT`. |
| `NUMBER(p,s)` | `NUMBER(p,s)` | Direct. |
| `DATE` | `TIMESTAMP_NTZ` | **Oracle `DATE` carries a time component.** Mapping to Snowflake `DATE` silently drops the time — must use `TIMESTAMP`. |
| `CLOB` | `VARCHAR` (up to 16 MB) | Snowflake has no LOB type. |
| `RAW` / `BLOB` | `BINARY` | Not used here but common. |

## 2. Sequences & key generation

- Oracle: `CREATE SEQUENCE`, `seq.NEXTVAL`, applied by a `BEFORE INSERT` trigger.
- Snowflake: use `CREATE SEQUENCE` + column `DEFAULT seq.NEXTVAL`, **or** an
  `IDENTITY`/`AUTOINCREMENT` column. Snowflake sequences are **not gap-free** and
  have no `CACHE`/`NOCACHE`, `CURRVAL`, or per-session `NEXTVAL` guarantees.
- `SELECT seq.NEXTVAL FROM dual` → `SELECT seq.NEXTVAL;` (no `DUAL` in Snowflake).

## 3. Triggers

Snowflake has **no row-level triggers**. Re-express:
- `trg_customer_biu` (PK default + `updated_ts`) → column `DEFAULT`s
  (`AUTOINCREMENT`, `DEFAULT CURRENT_TIMESTAMP`). "On update" timestamp must be
  set by the writing statement or a Stream+Task.
- `trg_policy_bi` → `policy_id NUMBER AUTOINCREMENT`.
- MV fast-refresh trigger semantics → **Streams + Tasks**.

## 4. PL/SQL → Snowflake Scripting

`claims_pkg` (a package) has no direct analog — Snowflake has no packages.
- Split each program unit into its own `CREATE PROCEDURE` (SQL Scripting or
  JavaScript) / `CREATE FUNCTION`.
- Package constant `g_default_reserve` → a scalar UDF or a config table.
- `RAISE_APPLICATION_ERROR` → Scripting `RAISE`/`EXCEPTION`.
- `RETURNING ... INTO` is not supported → re-query or use a Stream.
- Implicit `COMMIT` inside procedures differs; review transaction boundaries.

## 5. SQL construct rewrites

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

- `CREATE TABLESPACE`, `TABLESPACE ...` clauses — Snowflake is storage-managed.
- Function-based index `ix_cust_upper_name` — Snowflake has **no user indexes**;
  rely on micro-partitions / clustering keys if needed.
- All other `CREATE INDEX` statements — remove.
- Materialized view with joins (`mv_daily_paid` is fine — single table — but
  `REFRESH FAST ON COMMIT` → Snowflake MVs auto-maintain; drop the clause).

## 7. Java / JDBC layer

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

- `NightlyExtract` + `export_oracle_to_stage.sh` produce pipe-delimited flat
  files SFTP'd to the warehouse. Replace with `COPY INTO @stage` /
  **Snowpipe** for continuous load, eliminating the flat-file hop.
- `TRUNC(SYSDATE) - 1` window logic → `DATEADD` / Streams for CDC.

## 9. Suggested migration order (demo script)

1. Translate DDL (`db/oracle/01_schema.sql` → `db/snowflake/01_schema.sql`).
2. Rewrite views (`03_views.sql`) — remove `(+)`, `ROWNUM`.
3. Re-implement `claims_pkg` as Snowflake procedures.
4. Convert reporting SQL in `src/main/resources/sql/reports.sql`.
5. Swap the JDBC driver/config and rework `CallableStatement` calls.
6. Replace the flat-file ETL with `COPY INTO`/Snowpipe.
7. Re-point `application.properties` to the Snowflake datasource block.

## 10. Checklist

### DDL → `db/snowflake/01_schema.sql`
- [x] `VARCHAR2(n CHAR/BYTE)` → `VARCHAR(n)`; `NUMBER` → `NUMBER(38,0)`/`FLOAT` (`risk_score`); `DATE` → `TIMESTAMP_NTZ`; `CLOB` → `VARCHAR`
- [x] `DEFAULT SYSDATE` → `DEFAULT CURRENT_TIMESTAMP()`
- [x] Sequences recreated without `CACHE`/`NOCACHE`; PKs use `DEFAULT seq.NEXTVAL` (replaces `trg_customer_biu` / `trg_policy_bi` key assignment)
- [x] `CREATE TABLESPACE` and all `TABLESPACE` clauses dropped
- [x] All `CREATE INDEX` statements dropped, including function-based `ix_cust_upper_name` (clustering-key note left in place)
- [x] `CHECK` constraints removed (not enforced by Snowflake; documented as app-enforced)
- [x] `claim_payment_landing` added as the Snowpipe target

### Views → `db/snowflake/03_views.sql`
- [x] `(+)` → `LEFT JOIN` (`vw_active_policies`, `vw_claim_summary`)
- [x] `ROWNUM <= 10` → `QUALIFY ROW_NUMBER() OVER (...) <= 10` (`vw_top_open_claims`)
- [x] `DECODE` → `CASE`, `NVL` → `COALESCE`, `SYSDATE` → `CURRENT_TIMESTAMP()`, `TRUNC(date)` → `DATE_TRUNC('DAY', ...)`
- [x] `mv_daily_paid`: `BUILD IMMEDIATE REFRESH FAST ON COMMIT` dropped (auto-maintained MV)

### PL/SQL → `db/snowflake/02_procedures.sql` + `04_streams_tasks.sql`
- [x] `claims_pkg.g_default_reserve` → `default_reserve()` scalar UDF
- [x] `claims_pkg.open_claim` → `open_claim(...)` procedure (`RETURNS NUMBER`); `SELECT seq.NEXTVAL FROM dual` → `SELECT seq.NEXTVAL INTO :v`; `DUP_VAL_ON_INDEX` → explicit existence check + declared `EXCEPTION`
- [x] `claims_pkg.post_payment` → `post_payment(...)` procedure; `RETURNING ... INTO` → re-query; explicit `BEGIN TRANSACTION`/`COMMIT`/`ROLLBACK`
- [x] `claims_pkg.loss_ratio` → `loss_ratio()` SQL UDF (`DECODE`/`NVL` → `IFF`/`COALESCE`)
- [x] `fn_customer_full_name` → SQL UDF (returns NULL when no row, matching `NO_DATA_FOUND`)
- [x] `trg_customer_biu` `updated_ts` on UPDATE → `st_customer_changes` + `tk_customer_updated_ts`
- [x] `trg_policy_bi` → `policy_id DEFAULT seq_policy_id.NEXTVAL`
- [x] Payment application for pipe-loaded rows → `st_claim_payment_landing` + `tk_apply_landed_payments`

### Reporting SQL → `src/main/resources/sql/reports.sql`
- [x] `agent_org_chart`: `CONNECT BY`/`LEVEL`/`SYS_CONNECT_BY_PATH`/`ORDER SIBLINGS BY` → `WITH RECURSIVE` (depth counter, path built in CTE, `ORDER BY path`)
- [x] `monthly_premium`: `TO_CHAR` → `TO_VARCHAR`, `DECODE` → `CASE`, `NVL` → `COALESCE`, `ADD_MONTHS(SYSDATE, -24)` → `DATEADD('month', -24, CURRENT_TIMESTAMP())`
- [x] `stale_open_claims`: `ROWNUM` → `QUALIFY`, `SYSDATE - reported_date` → `DATEDIFF('day', ...)`
- [x] `customer_upsert`: `USING (... FROM dual)` dropped, `:1` binds → `?`, `SYSDATE` → `CURRENT_TIMESTAMP()`
- [x] `high_risk_customers`: `NVL2` → `IFF`
- [x] `changed_claims_export` added (`COPY INTO @claims_export`) for the nightly feed
- [x] `hartford.` schema qualifier dropped (schema set on the connection)

### Java / JDBC
- [x] `pom.xml`: `ojdbc11` → `net.snowflake:snowflake-jdbc`
- [x] `DataSourceFactory`: Snowflake driver/URL; `warehouse`/`db`/`schema`/`role` as datasource properties; `oracle.net.tns_admin`, `implicitStatementCacheSize`, `defaultRowPrefetch`, `ALTER SESSION SET CURRENT_SCHEMA` removed; password from `SNOWFLAKE_APP_PASSWORD`
- [x] `ClaimDao`: `CallableStatement` `{ ? = call ... }` → `CALL open_claim(?,?,?,?)` result set / `CALL post_payment(...)` / `SELECT loss_ratio(?)`
- [x] `CustomerDao.insert`: `getGeneratedKeys()` via ROWID → explicit `SELECT seq_customer_id.NEXTVAL` then insert; `peekNextId` drops `FROM dual`
- [x] `tnsnames.ora` deleted
- [x] `SqlLibraryTest` updated: asserts `WITH RECURSIVE` (not `CONNECT BY`) and no Oracle-only constructs remain

### ETL / batch
- [x] `NightlyExtract`: flat-file writer → `COPY INTO @claims_export/claims/<yyyymmdd>/` unload; `TRUNC(SYSDATE) - 1` → `DATEADD('day', -1, CURRENT_DATE())`
- [x] `scripts/export_oracle_to_stage.sh` (SQL*Plus spool) → `scripts/load_stage_to_snowflake.sh` (`COPY INTO` bulk cut-over load)
- [x] Snowpipe `pipe_claim_payments` → `claim_payment_landing` for continuous inbound payments (`db/snowflake/05_stage_pipe.sql`)

### Config
- [x] `application.properties` re-pointed to the Snowflake block; Oracle block and `db.tns.admin` / `db.pool.connectionInitSql` removed

### Post-cut-over (manual, needs the live account)
- [ ] Recreate sequences above `MAX(id)` after the bulk load (see `05_stage_pipe.sql`)
- [ ] Wire the S3 event notification to the `pipe_claim_payments` SQS channel
- [ ] Set the real `STORAGE_AWS_ROLE_ARN` on `int_hartford_claims_s3`
