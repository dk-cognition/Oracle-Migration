--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake physical schema (DDL), migrated from db/oracle/01_schema.sql.
--
-- Mapping notes (see docs/MIGRATION.md):
--   * VARCHAR2(n CHAR/BYTE)      -> VARCHAR(n)
--   * NUMBER (no precision)      -> NUMBER(38,0), or FLOAT for fractional columns
--   * DATE                       -> TIMESTAMP_NTZ (Oracle DATE carries a time part)
--   * CLOB                       -> VARCHAR (up to 16 MB)
--   * CREATE TABLESPACE / TABLESPACE clauses -> dropped (storage-managed)
--   * CREATE INDEX               -> dropped (no user indexes; micro-partitions)
--   * Sequences + BEFORE INSERT triggers -> column DEFAULT seq.NEXTVAL
--------------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS hartford;
USE SCHEMA hartford;

--------------------------------------------------------------------------------
-- Sequences (replace Oracle sequences + BEFORE INSERT triggers; applied via
-- column DEFAULTs below). Snowflake sequences have no CACHE/NOCACHE or CURRVAL.
--------------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE hartford.seq_customer_id START WITH 100000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE hartford.seq_policy_id   START WITH 500000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE hartford.seq_claim_id    START WITH 900000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE hartford.seq_payment_id  START WITH 1      INCREMENT BY 1;

--------------------------------------------------------------------------------
-- CUSTOMER
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.customer (
  customer_id      NUMBER(12,0)   NOT NULL DEFAULT hartford.seq_customer_id.NEXTVAL,
  first_name       VARCHAR(60),
  last_name        VARCHAR(60),
  ssn              VARCHAR(11),
  date_of_birth    TIMESTAMP_NTZ,
  email            VARCHAR(120),
  phone            VARCHAR(20),
  -- Oracle DATE carried a time component; TIMESTAMP_NTZ preserves it.
  created_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  updated_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  risk_score       FLOAT,
  lifetime_premium NUMBER(14,2)   DEFAULT 0,
  notes            VARCHAR,
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> queried with WITH RECURSIVE elsewhere)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.agent (
  agent_id         NUMBER(10,0)   NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10,0),
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES hartford.agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.policy (
  policy_id        NUMBER(12,0)   NOT NULL DEFAULT hartford.seq_policy_id.NEXTVAL,
  policy_number    VARCHAR(20)    NOT NULL,
  customer_id      NUMBER(12,0)   NOT NULL,
  agent_id         NUMBER(10,0),
  product_code     VARCHAR(10),                 -- AUTO / HOME / UMBRELLA / WC
  status           VARCHAR(12)    DEFAULT 'ACTIVE',
  effective_date   TIMESTAMP_NTZ  NOT NULL,
  expiration_date  TIMESTAMP_NTZ  NOT NULL,
  annual_premium   NUMBER(12,2)   NOT NULL,
  coverage_limit   NUMBER(14,2),
  deductible       NUMBER(10,2),
  created_ts       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_policy PRIMARY KEY (policy_id),
  CONSTRAINT uq_policy_number UNIQUE (policy_number),
  CONSTRAINT fk_policy_cust FOREIGN KEY (customer_id) REFERENCES hartford.customer (customer_id),
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES hartford.agent (agent_id)
  -- CHECK constraints are not enforced/supported in Snowflake; status domain
  -- ('ACTIVE','LAPSED','CANCELLED','PENDING') is validated in the app layer.
);

--------------------------------------------------------------------------------
-- CLAIM
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claim (
  claim_id         NUMBER(12,0)   NOT NULL DEFAULT hartford.seq_claim_id.NEXTVAL,
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
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES hartford.policy (policy_id)
  -- status domain ('OPEN','INVESTIGATING','APPROVED','DENIED','CLOSED') enforced in app layer.
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE hartford.claim_payment (
  payment_id       NUMBER(14,0)   NOT NULL DEFAULT hartford.seq_payment_id.NEXTVAL,
  claim_id         NUMBER(12,0)   NOT NULL,
  payment_date     TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  amount           NUMBER(14,2)   NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES hartford.claim (claim_id)
);

-- No CREATE INDEX statements: Snowflake has no user-managed indexes.
-- If pruning on claim.status or policy.customer_id becomes a hotspot, consider:
--   ALTER TABLE hartford.claim SET CLUSTER BY (status);
