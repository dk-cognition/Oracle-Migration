# Oracle 19c → Snowflake Migration Guide

This document catalogs every Oracle-specific construct in this repository and its
Snowflake equivalent. It is the working checklist for the migration demo.

> Scope: schema DDL, PL/SQL, reporting SQL, the Java JDBC data-access layer, and
> the nightly batch/ETL flow.

## Migration status

The Snowflake implementation is now the active target across the repository.
Schema and key-generation decisions are in `db/snowflake/01_schema.sql`;
procedures and UDFs are in `db/snowflake/02_procedures.sql`; views are in
`db/snowflake/03_views.sql`; and trigger replacement plus stage ingestion are in
`db/snowflake/04_streams_tasks.sql` and `db/snowflake/05_stages_pipes.sql`.

- Customer and claim ids retain explicit sequences because application/procedure
  code needs each value before or during its insert; policy and payment ids use
  `AUTOINCREMENT`.
- Snowflake does not support `CHECK` constraints, so the policy and claim status
  domains are enforced by the application or a downstream data-quality test.
- The package is split into standalone procedures and UDFs. `RETURNING` is
  replaced by a follow-up query, and procedure callers pass `NULL` because
  default procedure arguments are unavailable.
- `tnsnames.ora` and `export_oracle_to_stage.sh` were deleted. Flat-file ETL is
  replaced by `COPY INTO`/Snowpipe, and customer `updated_ts` maintenance uses a
  Stream + Task.

---

## 1. Data types

**Status: migrated in `db/snowflake/01_schema.sql`.**

| Oracle | Snowflake | Notes |
|--------|-----------|-------|
| `VARCHAR2(n CHAR)` / `VARCHAR2(n BYTE)` | `VARCHAR(n)` | Snowflake is always character-length; byte semantics disappear. |
| `NUMBER` (no precision) | `NUMBER(38,0)` or `FLOAT` | Decide per column; `risk_score` is fractional → `FLOAT`. |
| `NUMBER(p,s)` | `NUMBER(p,s)` | Direct. |
| `DATE` | `TIMESTAMP_NTZ` | **Oracle `DATE` carries a time component.** Mapping to Snowflake `DATE` silently drops the time — must use `TIMESTAMP`. |
| `CLOB` | `VARCHAR` (up to 16 MB) | Snowflake has no LOB type. |
| `RAW` / `BLOB` | `BINARY` | Not used here but common. |

## 2. Sequences & key generation

**Status: migrated in `db/snowflake/01_schema.sql` and the customer/claim
callers in `src/main/java`.**

- Oracle: `CREATE SEQUENCE`, `seq.NEXTVAL`, applied by a `BEFORE INSERT` trigger.
- Snowflake: use `CREATE SEQUENCE` + column `DEFAULT seq.NEXTVAL`, **or** an
  `IDENTITY`/`AUTOINCREMENT` column. Snowflake sequences are **not gap-free** and
  have no `CACHE`/`NOCACHE`, `CURRVAL`, or per-session `NEXTVAL` guarantees.
- `SELECT seq.NEXTVAL FROM dual` → `SELECT seq.NEXTVAL;` (no `DUAL` in Snowflake).

## 3. Triggers

**Status: migrated in `db/snowflake/01_schema.sql` and
`db/snowflake/04_streams_tasks.sql`.**

Snowflake has **no row-level triggers**. Re-express:
- `trg_customer_biu` (PK default + `updated_ts`) → the customer sequence
  default, timestamp column `DEFAULT`s, and a Stream+Task for changed rows.
  "On update" timestamp should ideally be set by the writing statement.
- `trg_policy_bi` → `policy_id NUMBER AUTOINCREMENT`.
- MV fast-refresh trigger semantics → **Streams + Tasks**.

## 4. PL/SQL → Snowflake Scripting

**Status: migrated in `db/snowflake/02_procedures.sql`.**

`claims_pkg` (a package) has no direct analog — Snowflake has no packages.
- Split each program unit into its own `CREATE PROCEDURE` (SQL Scripting or
  JavaScript) / `CREATE FUNCTION`.
- Package constant `g_default_reserve` → a scalar UDF or a config table.
- `RAISE_APPLICATION_ERROR` → Scripting `RAISE`/`EXCEPTION`.
- `RETURNING ... INTO` is not supported → re-query or use a Stream.
- `post_payment` re-queries the changed claim because `RETURNING ... INTO` is
  not supported, and omits the explicit `COMMIT` because Snowflake procedures
  are autocommit-by-statement.

## 5. SQL construct rewrites

**Status: migrated in `db/snowflake/03_views.sql` and
`src/main/resources/sql/reports.sql`.**

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

**Status: migrated in `db/snowflake/01_schema.sql`.**

- `CREATE TABLESPACE`, `TABLESPACE ...` clauses — Snowflake is storage-managed.
- Function-based index `ix_cust_upper_name` — Snowflake has **no user indexes**;
  rely on micro-partitions / clustering keys if needed.
- All other `CREATE INDEX` statements — remove.
- Materialized view with joins (`mv_daily_paid` is fine — single table — but
  `REFRESH FAST ON COMMIT` → Snowflake MVs auto-maintain; drop the clause).

## 7. Java / JDBC layer

**Status: migrated in
`src/main/java/com/thehartford/claims/config/DataSourceFactory.java`,
`src/main/java/com/thehartford/claims/dao/ClaimDao.java`,
`src/main/java/com/thehartford/claims/dao/CustomerDao.java`, and `pom.xml`.**

| Concern | Oracle today | Snowflake target |
|---------|--------------|------------------|
| Driver | `oracle.jdbc.OracleDriver` (`ojdbc11`) | `net.snowflake.client.jdbc.SnowflakeDriver` (`snowflake-jdbc`) |
| URL | `jdbc:oracle:thin:@HRTFD_PROD` + `tnsnames.ora` | `jdbc:snowflake://<account>.snowflakecomputing.com/?warehouse=...&db=...&role=...` |
| TNS | `oracle.net.tns_admin` system property, `tnsnames.ora` | none (delete the file) |
| Pool init SQL | `ALTER SESSION SET CURRENT_SCHEMA` | `USE SCHEMA` / set in URL |
| Vendor props | `implicitStatementCacheSize`, `defaultRowPrefetch` | remove (Snowflake-managed) |
| Stored-proc calls | `CallableStatement` `{ ? = call pkg.fn(...) }` | rework: Snowflake procs return one value; often push logic to app/dbt |
| Generated keys | `getGeneratedKeys()` via ROWID | not supported; `SELECT seq.CURRVAL` won't work either — obtain `seq.NEXTVAL` before insert |

Files to touch: `DataSourceFactory`, `ClaimDao` (all `CallableStatement` calls),
`CustomerDao.insert`/`peekNextId`, and every statement string in `reports.sql`.

## 8. ETL / batch

**Status: migrated in
`src/main/java/com/thehartford/claims/etl/NightlyExtract.java`,
`scripts/load_stage_to_snowflake.sh`, and
`db/snowflake/05_stages_pipes.sql`.**

- `NightlyExtract` + `export_oracle_to_stage.sh` produce pipe-delimited flat
  files SFTP'd to the warehouse. Replace with `COPY INTO @stage` /
  **Snowpipe** for continuous load, eliminating the flat-file hop.
- `TRUNC(SYSDATE) - 1` window logic → `DATEADD` / Streams for CDC.

## 9. Suggested migration order (demo script)

**Status: all steps completed; the target artifacts are listed below.**

1. Translate DDL (`db/oracle/01_schema.sql` → `db/snowflake/01_schema.sql`).
2. Rewrite views (`03_views.sql`) — remove `(+)`, `ROWNUM`.
3. Re-implement `claims_pkg` as Snowflake procedures.
4. Convert reporting SQL in `src/main/resources/sql/reports.sql`.
5. Swap the JDBC driver/config and rework `CallableStatement` calls.
6. Replace the flat-file ETL with `COPY INTO`/Snowpipe.
7. Re-point `application.properties` to the active Snowflake datasource block.
