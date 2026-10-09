--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL), translated from db/oracle/01_schema.sql.
--
-- Translation rules applied (see docs/MIGRATION.md sections 1-3 and 6):
--   DATE                   -> TIMESTAMP_NTZ (Oracle DATE carries a time component)
--   CLOB                   -> VARCHAR (16 MB max)
--   VARCHAR2(n CHAR|BYTE)  -> VARCHAR(n) (always character length)
--   NUMBER (unbounded)     -> FLOAT for risk_score (fractional)
--   DEFAULT SYSDATE        -> DEFAULT CURRENT_TIMESTAMP()
--   sequence + BEFORE INSERT trigger -> DEFAULT seq.NEXTVAL / AUTOINCREMENT
--   TABLESPACE clauses, CREATE TABLESPACE, all CREATE INDEX -> dropped
--   CHECK constraints      -> dropped (not supported); enforced in procedures
--
-- Snowflake declares but does NOT enforce PRIMARY KEY / UNIQUE / FOREIGN KEY
-- constraints (only NOT NULL is enforced). They are kept as metadata for BI
-- tools and the optimizer; writers must guarantee uniqueness themselves.
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS HARTFORD;
CREATE SCHEMA IF NOT EXISTS HARTFORD.CLAIMS;
USE SCHEMA HARTFORD.CLAIMS;

--------------------------------------------------------------------------------
-- Sequences. Snowflake has no CACHE/NOCACHE or CURRVAL, and sequences are not
-- gap-free. Start values are preserved so migrated keys stay in range.
--------------------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS seq_customer_id START = 100000 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS seq_claim_id    START = 900000 INCREMENT = 1;
CREATE SEQUENCE IF NOT EXISTS seq_payment_id  START = 1      INCREMENT = 1;
-- seq_policy_id is replaced by the AUTOINCREMENT column on POLICY.

--------------------------------------------------------------------------------
-- CUSTOMER
-- trg_customer_biu replaced by column defaults: customer_id from the sequence,
-- created_ts/updated_ts from CURRENT_TIMESTAMP(). updated_ts on UPDATE must be
-- set by the writing statement (see customer_upsert in reports.sql).
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer (
  customer_id      NUMBER(12)        DEFAULT seq_customer_id.NEXTVAL NOT NULL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  created_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  updated_ts       TIMESTAMP_NTZ     DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  risk_score       FLOAT,
  lifetime_premium NUMBER(14,2)      DEFAULT 0,
  notes            VARCHAR,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> recursive CTE in reports.sql)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE agent (
  agent_id         NUMBER(10)   NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10),
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
-- trg_policy_bi replaced by AUTOINCREMENT (starts where seq_policy_id did).
-- ck_policy_status ('ACTIVE','LAPSED','CANCELLED','PENDING') dropped: Snowflake
-- has no CHECK constraints.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE policy (
  policy_id        NUMBER(12)    AUTOINCREMENT START 500000 INCREMENT 1 ORDER NOT NULL,
  policy_number    VARCHAR(20)   NOT NULL,
  customer_id      NUMBER(12)    NOT NULL,
  agent_id         NUMBER(10),
  product_code     VARCHAR(10),
  status           VARCHAR(12)   DEFAULT 'ACTIVE',
  effective_date   TIMESTAMP_NTZ NOT NULL,
  expiration_date  TIMESTAMP_NTZ NOT NULL,
  annual_premium   NUMBER(12,2)  NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES agent (agent_id)
);

--------------------------------------------------------------------------------
-- CLAIM
-- claim_id comes from seq_claim_id; claims_open_claim reads NEXTVAL first so it
-- can build claim_number. ck_claim_status ('OPEN','INVESTIGATING','APPROVED',
-- 'DENIED','CLOSED') dropped: no CHECK constraints in Snowflake.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim (
  claim_id         NUMBER(12)    DEFAULT seq_claim_id.NEXTVAL NOT NULL,
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
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES policy (policy_id)
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim_payment (
  payment_id       NUMBER(14)    DEFAULT seq_payment_id.NEXTVAL NOT NULL,
  claim_id         NUMBER(12)    NOT NULL,
  payment_date     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP() NOT NULL,
  amount           NUMBER(14,2)  NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES claim (claim_id)
);

--------------------------------------------------------------------------------
-- Indexes: none. Snowflake has no user-defined indexes (including the former
-- function-based ix_cust_upper_name); pruning relies on micro-partitions. Add a
-- CLUSTER BY key only if query profiles show poor pruning on large tables.
--------------------------------------------------------------------------------
