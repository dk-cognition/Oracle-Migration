--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL), migrated from db/oracle/01_schema.sql.
--
-- Mapping applied (see docs/MIGRATION.md sections 1, 2, 3, 6):
--   VARCHAR2(n CHAR|BYTE) -> VARCHAR(n)        CLOB          -> VARCHAR
--   DATE                  -> TIMESTAMP_NTZ     NUMBER (bare) -> FLOAT
--   SYSDATE default       -> CURRENT_TIMESTAMP()
--   seq_policy_id / seq_payment_id -> AUTOINCREMENT column defaults
--   seq_customer_id / seq_claim_id -> sequence + DEFAULT seq.NEXTVAL, because
--     callers need the key before/after the INSERT and Snowflake has no
--     RETURNING or getGeneratedKeys() (CustomerDao.insert, open_claim).
--   trg_customer_biu / trg_policy_bi -> column DEFAULTs (no row triggers).
--   TABLESPACE clauses, CREATE TABLESPACE and all CREATE INDEX -> dropped.
--   CHECK constraints -> dropped (unsupported); allowed values are listed in
--     comments and enforced by the writing procedures.
--   PK / UNIQUE / FK constraints are kept as metadata; Snowflake does not
--     enforce them (only NOT NULL is enforced).
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS hartford;
CREATE SCHEMA IF NOT EXISTS hartford.claims;
USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Sequences (no CACHE/NOCACHE in Snowflake; values are unique but not gap-free)
--------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS hartford.claims.seq_customer_id START = 100000 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS hartford.claims.seq_claim_id    START = 900000 INCREMENT = 1;

--------------------------------------------------------------------------------
-- CUSTOMER
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hartford.claims.customer (
  customer_id      NUMBER(12)        DEFAULT hartford.claims.seq_customer_id.NEXTVAL NOT NULL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  created_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  -- Oracle trigger refreshed this on UPDATE; writers must now set it explicitly.
  updated_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  risk_score       FLOAT,
  lifetime_premium NUMBER(14,2)      DEFAULT 0,
  notes            VARCHAR,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT (self-referencing org chart; ids are assigned by the source system)
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hartford.claims.agent (
  agent_id         NUMBER(10)        NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10),
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES hartford.claims.agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hartford.claims.policy (
  policy_id        NUMBER(12)        AUTOINCREMENT START 500000 INCREMENT 1 ORDER NOT NULL,
  policy_number    VARCHAR(20)       NOT NULL,
  customer_id      NUMBER(12)        NOT NULL,
  agent_id         NUMBER(10),
  product_code     VARCHAR(10),                      -- AUTO / HOME / UMBRELLA / WC
  status           VARCHAR(12)       DEFAULT 'ACTIVE', -- ACTIVE / LAPSED / CANCELLED / PENDING
  effective_date   TIMESTAMP_NTZ     NOT NULL,
  expiration_date  TIMESTAMP_NTZ     NOT NULL,
  annual_premium   NUMBER(12,2)      NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES hartford.claims.customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES hartford.claims.agent (agent_id)
);

--------------------------------------------------------------------------------
-- CLAIM
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hartford.claims.claim (
  claim_id         NUMBER(12)        DEFAULT hartford.claims.seq_claim_id.NEXTVAL NOT NULL,
  claim_number     VARCHAR(24)       NOT NULL,
  policy_id        NUMBER(12)        NOT NULL,
  loss_date        TIMESTAMP_NTZ     NOT NULL,
  reported_date    TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  claim_type       VARCHAR(20),
  status           VARCHAR(16)       DEFAULT 'OPEN',   -- OPEN / INVESTIGATING / APPROVED / DENIED / CLOSED
  reserve_amount   NUMBER(14,2)      DEFAULT 0,
  paid_amount      NUMBER(14,2)      DEFAULT 0,
  adjuster_id      NUMBER(10),
  description      VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES hartford.claims.policy (policy_id)
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hartford.claims.claim_payment (
  payment_id       NUMBER(14)        AUTOINCREMENT START 1 INCREMENT 1 ORDER NOT NULL,
  claim_id         NUMBER(12)        NOT NULL,
  payment_date     TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  amount           NUMBER(14,2)      NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES hartford.claims.claim (claim_id)
);

-- Indexes from the Oracle schema (ix_policy_customer, ix_claim_policy,
-- ix_claim_status, function-based ix_cust_upper_name) are intentionally not
-- recreated: Snowflake has no user indexes and prunes via micro-partitions.
