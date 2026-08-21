# Oracle 19c → Snowflake Migration Guide

This document catalogs every Oracle-specific construct in this repository and its
Snowflake equivalent. It is the working checklist for the migration demo.

> Scope: schema DDL, PL/SQL, reporting SQL, the Java JDBC data-access layer, and
> the nightly batch/ETL flow.

**Status: migration complete.** The Snowflake artifacts live in `db/snowflake/`
and the Java/config layers now target Snowflake; `db/oracle/` is retained as the
source-system reference. Section 9 tracks the item-by-item status.

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

## 9. Migration order / status

- [x] **1. DDL** — `db/snowflake/01_schema.sql`: types remapped per section 1,
      tablespaces and all indexes dropped (clustering keys replace the access
      paths), sequence-driven `BEFORE INSERT` triggers replaced by column
      `DEFAULT seq.NEXTVAL` / `DEFAULT CURRENT_TIMESTAMP()`, and a
      `claims_config` table holding the former `g_default_reserve` constant.
- [x] **2. Views** — `db/snowflake/03_views.sql`: `(+)` → `LEFT JOIN`,
      `ROWNUM` → `QUALIFY ROW_NUMBER()`, `DECODE` → `CASE`, `NVL` →
      `COALESCE`, the `CONNECT BY` org chart → `WITH RECURSIVE`
      (`vw_agent_org_chart`), and `mv_daily_paid` keeps its single-table
      aggregate shape without the `BUILD IMMEDIATE` / `REFRESH FAST ON COMMIT`
      clauses.
- [x] **3. PL/SQL** — `db/snowflake/02_procedures.sql`: `claims_pkg` split into
      `sp_open_claim`, `sp_post_payment`, `fn_loss_ratio`, `fn_default_reserve`,
      plus `fn_customer_full_name`. `RAISE_APPLICATION_ERROR` → Scripting
      `EXCEPTION` + `RAISE`; `UPDATE ... RETURNING INTO` → re-query. Trigger
      side effects live in `db/snowflake/04_streams_tasks.sql` as Streams +
      Tasks.
- [x] **4. Reporting SQL / seed data** — `src/main/resources/sql/reports.sql`
      rewritten (`SYSDATE`, `ADD_MONTHS`, `NVL`/`NVL2`, `TO_CHAR`, `FROM dual`,
      `MERGE`), seed data in `db/snowflake/04_seed_data.sql`.
- [x] **5. JDBC layer** — `snowflake-jdbc` replaces `ojdbc11` in `pom.xml`;
      `DataSourceFactory` builds the account URL from
      `db.warehouse`/`db.database`/`db.schema`/`db.role` and drops
      `oracle.net.tns_admin`, the init SQL, and the vendor pool props;
      `ClaimDao` uses `CALL`/`SELECT` instead of `{ ? = call ... }`;
      `CustomerDao.insert` claims the id from the sequence (`peekNextId` →
      `nextId`, no `FROM dual`, no `getGeneratedKeys()`).
- [x] **6. ETL** — `NightlyExtract` now drives `COPY INTO @claims_stage` off the
      `strm_claim_cdc` stream (with a `DATEADD` backfill variant), inbound load
      is `COPY INTO`/Snowpipe in `db/snowflake/05_ingest.sql`, and
      `scripts/export_oracle_to_stage.sh` is replaced by
      `scripts/load_stage_to_snowflake.sh`.
- [x] **7. Config** — `application.properties` carries only the Snowflake
      datasource (password from `SNOWFLAKE_APP_PASSWORD`); `tnsnames.ora` is
      deleted.

### Carried-over caveats

- Snowflake parses but does not enforce `CHECK`, `UNIQUE`, or `NOT NULL`-adjacent
  constraints, so the Oracle status domains and the `claim_number` uniqueness are
  enforced in `sp_open_claim` / the load pipeline instead.
- Snowflake sequences are not gap-free and have no `CURRVAL`, so ids are claimed
  before the insert rather than read back afterwards.
- Procedures autocommit per statement; the Oracle `COMMIT` inside
  `post_payment` has no equivalent and transaction boundaries move to the caller.
