--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL), translated from db/oracle/01_schema.sql.
--
-- Mapping applied (see docs/MIGRATION.md):
--   VARCHAR2(n CHAR|BYTE) -> VARCHAR(n)      NUMBER (unbounded) -> NUMBER(38,0) / FLOAT
--   DATE                  -> TIMESTAMP_NTZ   CLOB               -> VARCHAR
--   SYSDATE default       -> CURRENT_TIMESTAMP()
--   sequence + BEFORE INSERT trigger -> DEFAULT seq.NEXTVAL / AUTOINCREMENT
--   TABLESPACE / CREATE INDEX -> dropped (Snowflake is storage-managed, no indexes)
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS hartford;
CREATE SCHEMA IF NOT EXISTS hartford.claims;
USE SCHEMA hartford.claims;

--------------------------------------------------------------------------------
-- Sequences (no CACHE/NOCACHE; Snowflake sequences are not gap-free).
-- seq_customer_id / seq_policy_id back the PK DEFAULTs that replace the
-- trg_customer_biu / trg_policy_bi row triggers. seq_claim_id / seq_payment_id
-- are consumed by the procedures in 02_procedures.sql.
--------------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE seq_customer_id START WITH 100000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE seq_policy_id   START WITH 500000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE seq_claim_id    START WITH 900000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE seq_payment_id  START WITH 1      INCREMENT BY 1;

--------------------------------------------------------------------------------
-- CUSTOMER
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE customer (
  customer_id      NUMBER(12,0)   NOT NULL DEFAULT seq_customer_id.NEXTVAL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  -- Oracle DATE carried a time component; TIMESTAMP_NTZ preserves it.
  created_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  -- "on update" maintenance moves to the writing statement / Stream+Task
  -- (see 04_streams_tasks.sql).
  updated_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  risk_score       FLOAT,                            -- fractional unbounded NUMBER
  lifetime_premium NUMBER(14,2)   DEFAULT 0,
  notes            VARCHAR,                          -- CLOB -> VARCHAR (16 MB max)
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> WITH RECURSIVE in reports.sql)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE agent (
  agent_id         NUMBER(10,0)   NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10,0),
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE policy (
  policy_id        NUMBER(12,0)   NOT NULL DEFAULT seq_policy_id.NEXTVAL,
  policy_number    VARCHAR(20)    NOT NULL,
  customer_id      NUMBER(12,0)   NOT NULL,
  agent_id         NUMBER(10,0),
  product_code     VARCHAR(10),                      -- AUTO / HOME / UMBRELLA / WC
  status           VARCHAR(12)    DEFAULT 'ACTIVE',
  effective_date   TIMESTAMP_NTZ  NOT NULL,
  expiration_date  TIMESTAMP_NTZ  NOT NULL,
  annual_premium   NUMBER(12,2)   NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust  FOREIGN KEY (customer_id) REFERENCES customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id)    REFERENCES agent (agent_id)
  -- Snowflake does not enforce CHECK constraints; the Oracle ck_policy_status
  -- rule (ACTIVE/LAPSED/CANCELLED/PENDING) is enforced by the application layer.
);

--------------------------------------------------------------------------------
-- CLAIM
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim (
  claim_id         NUMBER(12,0)   NOT NULL DEFAULT seq_claim_id.NEXTVAL,
  claim_number     VARCHAR(24)    NOT NULL,
  policy_id        NUMBER(12,0)   NOT NULL,
  loss_date        TIMESTAMP_NTZ  NOT NULL,
  reported_date    TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  claim_type       VARCHAR(20),
  status           VARCHAR(16)    DEFAULT 'OPEN',
  reserve_amount   NUMBER(14,2)   DEFAULT 0,
  paid_amount      NUMBER(14,2)   DEFAULT 0,
  adjuster_id      NUMBER(10,0),
  description      VARCHAR(4000),
  CONSTRAINT pk_claim PRIMARY KEY (claim_id),
  CONSTRAINT uq_claim_number UNIQUE (claim_number),
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES policy (policy_id)
  -- ck_claim_status (OPEN/INVESTIGATING/APPROVED/DENIED/CLOSED) enforced in app.
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim_payment (
  payment_id       NUMBER(14,0)   NOT NULL DEFAULT seq_payment_id.NEXTVAL,
  claim_id         NUMBER(12,0)   NOT NULL,
  payment_date     TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  amount           NUMBER(14,2)   NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES claim (claim_id)
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT_LANDING: Snowpipe target for externally sourced payments
-- (05_stage_pipe.sql). Drained into claim_payment/claim by tk_apply_landed_payments
-- (04_streams_tasks.sql). Replaces the legacy flat-file SFTP hop.
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim_payment_landing (
  claim_id         NUMBER(12,0)   NOT NULL,
  payment_date     TIMESTAMP_NTZ,
  amount           NUMBER(14,2)   NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  source_file      VARCHAR(512),
  loaded_ts        TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

--------------------------------------------------------------------------------
-- Indexes: none. Snowflake has no user-defined or function-based indexes
-- (ix_policy_customer, ix_claim_policy, ix_claim_status, ix_cust_upper_name all
-- dropped). Micro-partition pruning covers these access paths at this volume;
-- add a clustering key only if the claim table grows large enough to need it:
--   ALTER TABLE claim CLUSTER BY (policy_id, status);
--------------------------------------------------------------------------------
