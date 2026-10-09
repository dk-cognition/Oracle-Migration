# Oracle 19c → Snowflake Migration Guide

This document catalogs every Oracle-specific construct in this repository and its
Snowflake equivalent. It is the working checklist for the migration demo.

> **Status: migration steps 1-7 (section 9) are complete.** Snowflake artifacts
> live in `db/snowflake/`; the Java layer, reporting SQL, ETL and configuration
> now target Snowflake only. See [section 10](#10-migration-status--decisions)
> for what was done, design decisions, and remaining follow-ups.

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

- [x] 1. Translate DDL (`db/oracle/01_schema.sql` → `db/snowflake/01_schema.sql`).
- [x] 2. Rewrite views (`03_views.sql`) — remove `(+)`, `ROWNUM`.
- [x] 3. Re-implement `claims_pkg` as Snowflake procedures.
- [x] 4. Convert reporting SQL in `src/main/resources/sql/reports.sql`.
- [x] 5. Swap the JDBC driver/config and rework `CallableStatement` calls.
- [x] 6. Replace the flat-file ETL with `COPY INTO`/Snowpipe.
- [x] 7. Re-point `application.properties` to the Snowflake datasource block.

## 10. Migration status & decisions

Deploy order: `01_schema.sql` → `02_procedures.sql` → `03_views.sql` →
`05_etl_stage.sql` (all in `db/snowflake/`, target `HARTFORD.CLAIMS`).

### 10.1 Schema — `db/snowflake/01_schema.sql`
- All `DATE` → `TIMESTAMP_NTZ`, `CLOB` → `VARCHAR`, `VARCHAR2(n CHAR|BYTE)` →
  `VARCHAR(n)`, `risk_score NUMBER` → `FLOAT`; `NUMBER(p[,s])` unchanged.
- Keys: `customer_id`, `claim_id`, `payment_id` use `DEFAULT seq_*.NEXTVAL`
  (sequences keep their Oracle start values); `policy_id` is
  `AUTOINCREMENT START 500000`. `trg_customer_biu`/`trg_policy_bi` are replaced by
  column defaults; `updated_ts` on update is set by the writer (`customer_upsert`).
- Dropped: `CREATE TABLESPACE`, every `TABLESPACE` clause, all four
  `CREATE INDEX` statements (incl. function-based `ix_cust_upper_name`).
- **`CHECK` constraints dropped** (`ck_policy_status`, `ck_claim_status`) —
  Snowflake does not support them. PK/UNIQUE/FK are declared but **not enforced**.
- Objects are unqualified; the schema comes from `USE SCHEMA` / the JDBC URL
  (`db=HARTFORD&schema=CLAIMS`), replacing Oracle's `hartford.` prefix.

### 10.2 Views — `db/snowflake/03_views.sql`
- `(+)` → `LEFT JOIN`, `ROWNUM` → `QUALIFY ROW_NUMBER()`, `DECODE` → `CASE`,
  `NVL` → `COALESCE`, `SYSDATE` → `CURRENT_TIMESTAMP()`.
- `mv_daily_paid`: `REFRESH FAST ON COMMIT`/`BUILD IMMEDIATE` dropped,
  `TRUNC` → `DATE_TRUNC('DAY', …)`. Snowflake MVs require Enterprise Edition.
- The views contained no `CONNECT BY`/`NVL2`/`ADD_MONTHS`/`TO_CHAR`/`dual`;
  those rewrites are in `reports.sql`.

### 10.3 `claims_pkg` — `db/snowflake/02_procedures.sql`

| Oracle | Snowflake | Called from Java as |
|--------|-----------|---------------------|
| `claims_pkg.g_default_reserve` | UDF `claims_default_reserve()` | (used inside `claims_open_claim`) |
| `claims_pkg.open_claim` | procedure `claims_open_claim` → `NUMBER` | `CALL claims_open_claim(?, TO_TIMESTAMP_NTZ(?, …), ?, ?)` |
| `claims_pkg.post_payment` | procedure `claims_post_payment` → claim status | `CALL claims_post_payment(?, ?, ?, ?)` |
| `claims_pkg.loss_ratio` | UDF `claims_loss_ratio` | `SELECT claims_loss_ratio(?)` |
| `fn_customer_full_name` | UDF `fn_customer_full_name` | — |

- `RAISE_APPLICATION_ERROR(-20001, …)` → declared `EXCEPTION (-20001, …)` + `RAISE`.
- `RETURNING reserve_amount, paid_amount INTO` → re-`SELECT` after the `UPDATE`.
- Constraint-driven checks are explicit: duplicate `claim_number` (was
  `DUP_VAL_ON_INDEX`) and unknown claim in `post_payment` (was the FK) raise
  `-20001`/`-20002`. `post_payment` runs in an explicit transaction with
  `ROLLBACK` on error.
- `claims_loss_ratio` returns `NULL` for an unknown policy (Oracle raised
  `NO_DATA_FOUND`); `ClaimDao.lossRatio` turns that into a `DataAccessException`.

### 10.4 Reporting SQL — `src/main/resources/sql/reports.sql`
- `agent_org_chart`: `WITH RECURSIVE` CTE; `LEVEL` → `depth`,
  `SYS_CONNECT_BY_PATH` → accumulated `path` (same leading `' > '`),
  `ORDER SIBLINGS BY` → sort key of zero-padded per-parent `ROW_NUMBER()`s.
- `monthly_premium`: `TO_VARCHAR`, `CASE`, `COALESCE`, `DATEADD('month', -24, …)`.
- `stale_open_claims`: `LIMIT 100`, `DATEDIFF('day', …)`, `DATEADD('day', -30, …)`.
- `customer_upsert`: `USING (SELECT ? …)` (no `dual`, `:n` → `?`), sets `updated_ts`.
- `high_risk_customers`: `NVL2` → `IFF`; regex `'^860-'` → `'860-.*'` because
  Snowflake `REGEXP_LIKE` must match the whole string.
- Semantic notes: `DATEDIFF('day', …)` counts day boundaries whereas Oracle
  `ROUND(SYSDATE - d)` rounded fractional days (can differ by 1);
  `DATEADD('month', …)` does not apply Oracle's last-day-of-month rule.

### 10.5 Java layer
- `pom.xml`: `ojdbc11` → `net.snowflake:snowflake-jdbc:3.28.0`
  (driver `net.snowflake.client.jdbc.SnowflakeDriver`). The 4.x line moves the
  driver to `net.snowflake.client.api.driver.SnowflakeDriver`; evaluate separately.
- `DataSourceFactory`: builds
  `jdbc:snowflake://<db.account>.snowflakecomputing.com/?warehouse=…&db=…&schema=…&role=…`
  (or uses `db.url` verbatim). No `oracle.net.tns_admin`, no init SQL, no
  `implicitStatementCacheSize`/`defaultRowPrefetch`. Credentials from env:
  `SNOWFLAKE_PRIVATE_KEY_FILE` (+ `SNOWFLAKE_PRIVATE_KEY_PWD`) for key-pair auth,
  else `SNOWFLAKE_APP_PASSWORD`.
- `tnsnames.ora` deleted.
- `ClaimDao`: all `CallableStatement`/`{? = call …}` calls replaced (table above).
  The loss date is bound as text and parsed with `TO_TIMESTAMP_NTZ` to avoid
  JVM/session time-zone shifts on `TIMESTAMP_NTZ`.
- `CustomerDao.insert` draws `SELECT seq_customer_id.NEXTVAL` then inserts the id
  explicitly (no `getGeneratedKeys()`/ROWID); `peekNextId` uses the same query
  without `FROM dual`.
- Running on JDK 16+ with the default Arrow result format needs
  `--add-opens=java.base/java.nio=ALL-UNNAMED` (not needed on Java 11).

### 10.6 ETL
- `NightlyExtract` runs one
  `COPY INTO @claims_extract_stage/claims/<run-date>/claims_changed_ FROM (SELECT …)`
  with window `reported_date >= DATEADD('day', -1, CURRENT_DATE())` (was
  `TRUNC(SYSDATE) - 1`) and returns `rows_unloaded`. Stage and file format come
  from `etl.stage` / `etl.fileFormat`.
- `scripts/export_oracle_to_stage.sh` now unloads every table with
  `COPY INTO @stage/<table>/<run-date>/` through the Snowflake CLI (`snow sql`);
  `DRY_RUN=1` prints the SQL. No SQL*Plus spool, no SFTP.
- `db/snowflake/05_etl_stage.sql` creates `psv_format` (pipe-delimited, no
  header, uncompressed `.psv`) and an internal stage `claims_extract_stage`
  (swap for an external S3/Azure/GCS stage via a storage integration).

### 10.7 Remaining follow-ups
- Not run against a live Snowflake account yet: DDL, procedures, and the JDBC
  layer need a smoke test in a real environment.
- `db/oracle/04_seed_data.sql` has no Snowflake counterpart yet.
- Streams + Tasks for change capture (`04_streams_tasks.sql`) were not needed by
  the current code paths and are not built.
- Historical data load from Oracle (one-off `COPY INTO <table> FROM @stage`) is
  out of scope here; Snowpipe applies if ongoing inbound feeds are added.
- Rename `scripts/export_oracle_to_stage.sh` once downstream schedulers are updated.
