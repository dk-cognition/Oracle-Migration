--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL), migrated from Oracle 19c.
--
-- Migration notes (see docs/MIGRATION.md):
--   * VARCHAR2(n CHAR/BYTE)      -> VARCHAR(n)  (Snowflake is character-length)
--   * NUMBER (no precision)      -> NUMBER(38,0), or FLOAT for fractional columns
--   * DATE (with time component) -> TIMESTAMP_NTZ (preserves the time component)
--   * CLOB                       -> VARCHAR (max 16 MB)
--   * Tablespaces / indexes      -> dropped (Snowflake is storage-managed,
--                                   no user indexes; rely on micro-partitions)
--   * Sequences + BEFORE INSERT triggers -> IDENTITY columns / DEFAULT
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS hartford;
CREATE SCHEMA IF NOT EXISTS hartford.claims;

USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Sequences
-- Retained only where application code peeks at ids (customer). Other PKs use
-- IDENTITY columns. Snowflake sequences are not gap-free and have no
-- CACHE/NOCACHE or CURRVAL.
--------------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE seq_customer_id START WITH 100000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE seq_claim_id    START WITH 900000 INCREMENT BY 1;

--------------------------------------------------------------------------------
-- CUSTOMER
-- Oracle trg_customer_biu (PK from sequence + created/updated timestamps) is
-- replaced by column DEFAULTs. updated_ts on UPDATE must be set by the writing
-- statement (see 04_streams_tasks.sql for the Stream+Task alternative).
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer (
  customer_id      NUMBER(12,0)   NOT NULL DEFAULT seq_customer_id.NEXTVAL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  created_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  updated_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  risk_score       FLOAT,
  lifetime_premium NUMBER(14,2)   DEFAULT 0,
  notes            VARCHAR,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> WITH RECURSIVE elsewhere)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE agent (
  agent_id         NUMBER(10,0)  NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10,0),
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY  (Oracle trg_policy_bi replaced by AUTOINCREMENT)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE policy (
  policy_id        NUMBER(12,0)  NOT NULL AUTOINCREMENT START 500000 INCREMENT 1,
  policy_number    VARCHAR(20)   NOT NULL,
  customer_id      NUMBER(12,0)  NOT NULL,
  agent_id         NUMBER(10,0),
  product_code     VARCHAR(10),                 -- AUTO / HOME / UMBRELLA / WC
  status           VARCHAR(12)   DEFAULT 'ACTIVE',
  effective_date   TIMESTAMP_NTZ NOT NULL,
  expiration_date  TIMESTAMP_NTZ NOT NULL,
  annual_premium   NUMBER(12,2)  NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES agent (agent_id)
  -- CHECK constraints are not enforced/supported in Snowflake; the
  -- ck_policy_status rule ('ACTIVE','LAPSED','CANCELLED','PENDING') is
  -- enforced by the writing procedures.
);

--------------------------------------------------------------------------------
-- CLAIM  (claim_id from seq_claim_id: sp_open_claim fetches NEXTVAL explicitly
-- to build the claim_number, so a sequence default beats AUTOINCREMENT here)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim (
  claim_id         NUMBER(12,0)  NOT NULL DEFAULT seq_claim_id.NEXTVAL,
  claim_number     VARCHAR(24)   NOT NULL,
  policy_id        NUMBER(12,0)  NOT NULL,
  loss_date        TIMESTAMP_NTZ NOT NULL,
  reported_date    TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  claim_type       VARCHAR(20),
  status           VARCHAR(16)   DEFAULT 'OPEN',
  reserve_amount   NUMBER(14,2)  DEFAULT 0,
  paid_amount      NUMBER(14,2)  DEFAULT 0,
  adjuster_id      NUMBER(10,0),
  description      VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES policy (policy_id)
  -- ck_claim_status ('OPEN','INVESTIGATING','APPROVED','DENIED','CLOSED')
  -- enforced by the writing procedures.
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT  (payment_id from AUTOINCREMENT, replacing seq_payment_id)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim_payment (
  payment_id       NUMBER(14,0)  NOT NULL AUTOINCREMENT START 1 INCREMENT 1,
  claim_id         NUMBER(12,0)  NOT NULL,
  payment_date     TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  amount           NUMBER(14,2)  NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES claim (claim_id)
);

--------------------------------------------------------------------------------
-- Indexes: intentionally omitted. Snowflake has no user indexes (including the
-- Oracle function-based ix_cust_upper_name); micro-partition pruning covers
-- these access paths. Add clustering keys only if profiling shows a need, e.g.:
--   ALTER TABLE claim CLUSTER BY (status);
--------------------------------------------------------------------------------
