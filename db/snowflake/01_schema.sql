--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL) -- migrated from Oracle 19c (db/oracle/01_schema.sql).
--
-- Migration notes (see docs/MIGRATION.md):
--   * No TABLESPACE / DATAFILE (Snowflake is storage-managed).
--   * No CREATE INDEX (Snowflake has no user indexes; rely on micro-partitions
--     / clustering keys). The function-based index ix_cust_upper_name is dropped.
--   * Oracle DATE -> TIMESTAMP_NTZ (preserves the time component).
--   * Unbounded NUMBER -> NUMBER(38,0), except risk_score (fractional) -> FLOAT.
--   * VARCHAR2(n CHAR|BYTE) -> VARCHAR(n); CLOB -> VARCHAR.
--   * Sequences + BEFORE INSERT triggers -> IDENTITY/AUTOINCREMENT columns and
--     column DEFAULTs (see also db/snowflake/02_packages.sql).
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS HARTFORD;
CREATE SCHEMA IF NOT EXISTS HARTFORD.CLAIMS;
USE SCHEMA HARTFORD.CLAIMS;

--------------------------------------------------------------------------------
-- Sequences
-- open_claim needs the id value before the row exists (to build claim_number),
-- so claim_id is served by an explicit sequence rather than AUTOINCREMENT.
-- Snowflake sequences are not gap-free and have no CACHE/NOCACHE/CURRVAL.
--------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS seq_claim_id START = 900000 INCREMENT = 1;

--------------------------------------------------------------------------------
-- CUSTOMER
-- customer_id: AUTOINCREMENT replaces seq_customer_id + trg_customer_biu.
-- created_ts / updated_ts: DEFAULT CURRENT_TIMESTAMP replaces the trigger.
--   The "on update" refresh of updated_ts is now the writing statement's job
--   (see customer_upsert in reports.sql) or a Stream+Task.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer (
  customer_id      NUMBER(12)     NOT NULL AUTOINCREMENT START 100000 INCREMENT 1,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  created_ts       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP NOT NULL,
  updated_ts       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP NOT NULL,
  risk_score       FLOAT,                         -- unconstrained Oracle NUMBER -> FLOAT
  lifetime_premium NUMBER(14,2)   DEFAULT 0,
  notes            VARCHAR,                        -- CLOB -> VARCHAR
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> WITH RECURSIVE elsewhere)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE agent (
  agent_id         NUMBER(10)   NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10),                    -- FK to agent_id (org chart)
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
-- policy_id: AUTOINCREMENT replaces seq_policy_id + trg_policy_bi.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE policy (
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
  created_ts       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP NOT NULL,
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES agent (agent_id),
  CONSTRAINT ck_policy_status CHECK (status IN ('ACTIVE','LAPSED','CANCELLED','PENDING'))
);

--------------------------------------------------------------------------------
-- CLAIM  (claim_id assigned from seq_claim_id by open_claim; see 02_packages.sql)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim (
  claim_id         NUMBER(12)    NOT NULL,
  claim_number     VARCHAR(24)   NOT NULL,
  policy_id        NUMBER(12)    NOT NULL,
  loss_date        TIMESTAMP_NTZ NOT NULL,
  reported_date    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP NOT NULL,
  claim_type       VARCHAR(20),
  status           VARCHAR(16)   DEFAULT 'OPEN',
  reserve_amount   NUMBER(14,2)  DEFAULT 0,
  paid_amount      NUMBER(14,2)  DEFAULT 0,
  adjuster_id      NUMBER(10),
  description      VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES policy (policy_id),
  CONSTRAINT ck_claim_status CHECK (status IN ('OPEN','INVESTIGATING','APPROVED','DENIED','CLOSED'))
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT  (payment_id: AUTOINCREMENT replaces seq_payment_id)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim_payment (
  payment_id       NUMBER(14)    NOT NULL AUTOINCREMENT START 1 INCREMENT 1,
  claim_id         NUMBER(12)    NOT NULL,
  payment_date     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP NOT NULL,
  amount           NUMBER(14,2)  NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES claim (claim_id)
);

--------------------------------------------------------------------------------
-- Indexes: intentionally omitted.
-- Oracle ix_policy_customer, ix_claim_policy, ix_claim_status and the
-- function-based ix_cust_upper_name (UPPER(last_name)) are dropped -- Snowflake
-- has no user indexes. If read patterns require it, add a clustering key, e.g.:
--   ALTER TABLE claim CLUSTER BY (status);
--------------------------------------------------------------------------------
