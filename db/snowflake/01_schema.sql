--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL) -- migrated from db/oracle/01_schema.sql
--
-- Domain: Property & Casualty policy administration + claims processing.
-- See docs/MIGRATION.md for the construct-by-construct Oracle -> Snowflake mapping.
--
-- Migration highlights (vs. the Oracle source):
--   * No tablespaces: Snowflake is storage-managed, so CREATE TABLESPACE and all
--     TABLESPACE clauses are dropped.
--   * ALTER SESSION SET CURRENT_SCHEMA -> CREATE DATABASE/SCHEMA + USE SCHEMA.
--   * VARCHAR2(n CHAR|BYTE) -> VARCHAR(n); unbounded NUMBER -> NUMBER(38,0)
--     (risk_score, which is fractional, -> FLOAT); CLOB -> VARCHAR.
--   * Oracle DATE (date + time) -> TIMESTAMP_NTZ; DEFAULT SYSDATE ->
--     DEFAULT CURRENT_TIMESTAMP().
--   * Sequences + BEFORE-INSERT triggers -> AUTOINCREMENT identity columns
--     (customer_id, policy_id, payment_id) and a retained sequence for claim_id
--     (open_claim needs the value to build the claim_number). The "on update"
--     updated_ts is set by the writing statement (see customer_upsert / MERGE)
--     or a Stream+Task (see 04_streams_tasks.sql).
--   * All CREATE INDEX statements removed (incl. the function-based
--     ix_cust_upper_name); Snowflake has no user indexes. PK/FK/UNIQUE/CHECK
--     constraints are kept.
--------------------------------------------------------------------------------

-- Dedicated database + schema (replaces ALTER SESSION SET CURRENT_SCHEMA = HARTFORD).
CREATE DATABASE IF NOT EXISTS hartford;
CREATE SCHEMA IF NOT EXISTS hartford.hartford;
USE SCHEMA hartford.hartford;

--------------------------------------------------------------------------------
-- Sequence retained for claim_id: open_claim reads NEXTVAL to build the
-- claim_number before insert. (Snowflake sequences are not gap-free and have no
-- CACHE/NOCACHE, CURRVAL, or per-session NEXTVAL guarantees.)
--------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS hartford.seq_claim_id START WITH 900000 INCREMENT BY 1;

--------------------------------------------------------------------------------
-- CUSTOMER
--------------------------------------------------------------------------------
CREATE TABLE hartford.customer (
  customer_id      NUMBER(12)        NOT NULL AUTOINCREMENT START 100000 INCREMENT 1,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  -- Oracle DATE carries a time component; downstream code relies on it.
  created_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  updated_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  risk_score       FLOAT,                        -- unbounded Oracle NUMBER -> FLOAT
  lifetime_premium NUMBER(14,2)      DEFAULT 0,
  notes            VARCHAR,                       -- Oracle CLOB
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> demoed with WITH RECURSIVE elsewhere)
--------------------------------------------------------------------------------
CREATE TABLE hartford.agent (
  agent_id         NUMBER(10)   NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10),                    -- FK to agent_id (org chart)
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES hartford.agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
--------------------------------------------------------------------------------
CREATE TABLE hartford.policy (
  policy_id        NUMBER(12)    NOT NULL AUTOINCREMENT START 500000 INCREMENT 1,
  policy_number    VARCHAR(20)   NOT NULL,
  customer_id      NUMBER(12)    NOT NULL,
  agent_id         NUMBER(10),
  product_code     VARCHAR(10),                   -- AUTO / HOME / UMBRELLA / WC
  status           VARCHAR(12)   DEFAULT 'ACTIVE',
  effective_date   TIMESTAMP_NTZ NOT NULL,
  expiration_date  TIMESTAMP_NTZ NOT NULL,
  annual_premium   NUMBER(12,2)  NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES hartford.customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES hartford.agent (agent_id),
  CONSTRAINT ck_policy_status CHECK (status IN ('ACTIVE','LAPSED','CANCELLED','PENDING'))
);

--------------------------------------------------------------------------------
-- CLAIM
--------------------------------------------------------------------------------
CREATE TABLE hartford.claim (
  claim_id         NUMBER(12)    NOT NULL,
  claim_number     VARCHAR(24)   NOT NULL,
  policy_id        NUMBER(12)    NOT NULL,
  loss_date        TIMESTAMP_NTZ NOT NULL,
  reported_date    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  claim_type       VARCHAR(20),
  status           VARCHAR(16)   DEFAULT 'OPEN',
  reserve_amount   NUMBER(14,2)  DEFAULT 0,
  paid_amount      NUMBER(14,2)  DEFAULT 0,
  adjuster_id      NUMBER(10),
  description      VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES hartford.policy (policy_id),
  CONSTRAINT ck_claim_status CHECK (status IN ('OPEN','INVESTIGATING','APPROVED','DENIED','CLOSED'))
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE TABLE hartford.claim_payment (
  payment_id       NUMBER(14)    NOT NULL AUTOINCREMENT START 1 INCREMENT 1,
  claim_id         NUMBER(12)    NOT NULL,
  payment_date     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  amount           NUMBER(14,2)  NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES hartford.claim (claim_id)
);

--------------------------------------------------------------------------------
-- Indexes: intentionally none. Snowflake has no user (or function-based)
-- indexes; the Oracle ix_policy_customer / ix_claim_policy / ix_claim_status /
-- ix_cust_upper_name indexes are dropped. Add a CLUSTER BY key only if a
-- specific large-table access pattern justifies it, e.g.:
--   ALTER TABLE hartford.claim CLUSTER BY (status);
--------------------------------------------------------------------------------
