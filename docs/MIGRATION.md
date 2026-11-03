# Oracle 19c → Snowflake Migration Guide

This document catalogs every Oracle-specific construct in this repository and its
Snowflake equivalent. It is the working checklist for the migration demo.

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

- `NightlyExtract` + `export_oracle_to_stage.sh` (now `unload_to_stage.sh`)
  produced pipe-delimited flat files SFTP'd to the warehouse. Replace with `COPY INTO @stage` /
  **Snowpipe** for continuous load, eliminating the flat-file hop.
- `TRUNC(SYSDATE) - 1` window logic → `DATEADD` / Streams for CDC.

## 9. Suggested migration order (demo script)

- [x] 1. Translate DDL (`db/oracle/01_schema.sql` → `db/snowflake/01_schema.sql`).
  `VARCHAR2`/`CLOB` → `VARCHAR`, `DATE` → `TIMESTAMP_NTZ`, `customer_id` →
  `DEFAULT seq_customer_id.NEXTVAL`, `policy_id`/`payment_id` → `AUTOINCREMENT`,
  `updated_ts` → `DEFAULT CURRENT_TIMESTAMP()`. Tablespaces, all indexes, and
  `CHECK` constraints (unsupported) dropped; PK/UK/FK kept as metadata.
  Seed data ported to `db/snowflake/04_seed_data.sql`.
- [x] 2. Rewrite views (`03_views.sql`) — remove `(+)`, `ROWNUM`.
  → `db/snowflake/03_views.sql`: ANSI `LEFT JOIN`, `CASE`, `COALESCE`,
  `LIMIT 10`, `mv_daily_paid` without `REFRESH FAST ON COMMIT`, plus
  `vw_agent_org_chart` (`CONNECT BY` → `WITH RECURSIVE`).
- [x] 3. Re-implement `claims_pkg` as Snowflake procedures.
  → `db/snowflake/02_procedures.sql`: `open_claim` / `post_payment`
  (Snowflake Scripting procedures), `loss_ratio` / `fn_customer_full_name`
  (SQL UDFs), `claims_default_reserve()` replaces `g_default_reserve`.
  `RAISE_APPLICATION_ERROR` → named `EXCEPTION`s; the claim id is taken from
  `seq_claim_id.NEXTVAL` up front instead of `RETURNING ... INTO`.
- [x] 4. Convert reporting SQL in `src/main/resources/sql/reports.sql`.
  `SqlLibraryTest` now asserts `WITH RECURSIVE` and the absence of Oracle-isms.
- [x] 5. Swap the JDBC driver/config and rework `CallableStatement` calls.
  `ojdbc11` → `snowflake-jdbc`; `tnsnames.ora` deleted; `DataSourceFactory`
  passes warehouse/db/schema/role as connection properties and supports
  key-pair (`SNOWFLAKE_PRIVATE_KEY_FILE` [+ `_PWD`]) or password
  (`SNOWFLAKE_APP_PASSWORD`) auth. `ClaimDao` uses `CALL open_claim(...)`,
  `CALL post_payment(...)`, `SELECT loss_ratio(?)`; `CustomerDao` takes
  `SELECT seq_customer_id.NEXTVAL` and inserts it explicitly.
- [x] 6. Replace the flat-file ETL with `COPY INTO`/Snowpipe.
  `NightlyExtract` unloads changed claims with `COPY INTO @claims_extract_stage/<date>/`;
  `scripts/export_oracle_to_stage.sh` → `scripts/unload_to_stage.sh` (`snow sql`,
  `COPY INTO` per table, `DRY_RUN=1` to print). Stage + file format in
  `db/snowflake/05_etl_stage.sql`; consumers ingest with Snowpipe (template there).
- [x] 7. Re-point `application.properties` to the Snowflake datasource block.

### Cutover notes / remaining work

- **Snowpipe** needs a real external stage + storage integration on the
  consumer side; `05_etl_stage.sql` has the `CREATE PIPE ... AUTO_INGEST`
  template but no live pipe is created.
- **`CHECK` constraints** (claim/policy status, amounts ≥ 0) are not enforced by
  Snowflake. `post_payment` enforces payment rules; add data-quality checks for
  direct writers.
- **Sequence gaps/order:** Snowflake sequences hand out ids in blocks and are
  not guaranteed monotonic across sessions (observed `100203` then `100004`).
  Nothing in the app assumes gap-free or ordered ids; `peekNextId` is advisory.
- **JDBC driver settings** in `DataSourceFactory`: `JDBC_QUERY_RESULT_FORMAT=JSON`
  (Arrow needs `--add-opens java.base/java.nio` on JDK 17+),
  `CLIENT_RESULT_COLUMN_CASE_INSENSITIVE=true` (DAOs read lower-case column
  labels), and BouncyCastle enabled for encrypted private keys.
- **Seed dates** are 2024–2025, so date-windowed views/reports
  (`vw_active_policies`, `monthly_premium`) return no rows once those policies
  expire; that is the data, not the SQL.
- `updated_ts` has no on-update trigger; `customer_upsert` sets it explicitly.
  Add a Stream + Task if other writers need it maintained.
