--------------------------------------------------------------------------------
-- The Hartford - Claims Data Store
-- Snowflake schema (DDL), migrated from db/oracle/01_schema.sql.
--
-- Migration notes (see docs/MIGRATION.md):
--   * VARCHAR2(n CHAR/BYTE)      -> VARCHAR(n)  (Snowflake is character-length)
--   * Unbounded NUMBER           -> NUMBER(38,0), except fractional columns
--                                   (risk_score) -> FLOAT
--   * DATE                       -> TIMESTAMP_NTZ (Oracle DATE carries a time
--                                   component; Snowflake DATE would drop it)
--   * CLOB                       -> VARCHAR (Snowflake has no LOB type)
--   * BEFORE INSERT PK triggers  -> AUTOINCREMENT / DEFAULT seq.NEXTVAL
--   * updated_ts trigger         -> DEFAULT CURRENT_TIMESTAMP (writers or a
--                                   Stream+Task must maintain it on UPDATE)
--   * Tablespaces and all CREATE INDEX statements (including the function-based
--     index ix_cust_upper_name) are dropped -- Snowflake is storage-managed and
--     has no user indexes; use clustering keys if pruning is ever needed.
--------------------------------------------------------------------------------

USE SCHEMA hartford;

--------------------------------------------------------------------------------
-- Sequences (kept for claim/payment ids so numbering matches the Oracle system;
-- customer/policy ids use AUTOINCREMENT instead of trigger-applied sequences).
-- Snowflake sequences are not gap-free and have no CACHE/NOCACHE or CURRVAL.
--------------------------------------------------------------------------------
CREATE OR REPLACE SEQUENCE seq_claim_id   START WITH 900000 INCREMENT BY 1;
CREATE OR REPLACE SEQUENCE seq_payment_id START WITH 1      INCREMENT BY 1;

--------------------------------------------------------------------------------
-- CUSTOMER
-- (trg_customer_biu replaced by AUTOINCREMENT + DEFAULT CURRENT_TIMESTAMP)
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
  -- "On update" semantics of the Oracle trigger must be handled by the writing
  -- statement (SET updated_ts = CURRENT_TIMESTAMP) or a Stream+Task.
  updated_ts       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP NOT NULL,
  risk_score       FLOAT,                        -- fractional; was unbounded NUMBER
  lifetime_premium NUMBER(14,2)   DEFAULT 0,
  notes            VARCHAR,                      -- was CLOB
  CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

--------------------------------------------------------------------------------
-- AGENT  (self-referencing hierarchy -> WITH RECURSIVE elsewhere)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE agent (
  agent_id         NUMBER(10)   NOT NULL,
  agent_name       VARCHAR(120),
  manager_id       NUMBER(10),                   -- FK to agent_id (org chart)
  region_code      VARCHAR(4),
  hire_date        TIMESTAMP_NTZ,
  CONSTRAINT pk_agent PRIMARY KEY (agent_id),
  CONSTRAINT fk_agent_mgr FOREIGN KEY (manager_id) REFERENCES agent (agent_id)
);

--------------------------------------------------------------------------------
-- POLICY
-- (trg_policy_bi replaced by AUTOINCREMENT)
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE policy (
  policy_id        NUMBER(12)    NOT NULL AUTOINCREMENT START 500000 INCREMENT 1,
  policy_number    VARCHAR(20)   NOT NULL,
  customer_id      NUMBER(12)    NOT NULL,
  agent_id         NUMBER(10),
  product_code     VARCHAR(10),                  -- AUTO / HOME / UMBRELLA / WC
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
  CONSTRAINT fk_policy_agent FOREIGN KEY (agent_id) REFERENCES agent (agent_id)
  -- NOTE: CHECK constraints are not enforced (or supported) by Snowflake;
  -- ck_policy_status ('ACTIVE','LAPSED','CANCELLED','PENDING') must be enforced
  -- by the application layer.
);

--------------------------------------------------------------------------------
-- CLAIM
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim (
  claim_id         NUMBER(12)    NOT NULL DEFAULT seq_claim_id.NEXTVAL,
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
  CONSTRAINT fk_claim_policy FOREIGN KEY (policy_id) REFERENCES policy (policy_id)
  -- NOTE: ck_claim_status ('OPEN','INVESTIGATING','APPROVED','DENIED','CLOSED')
  -- must be enforced by the application layer (no CHECK enforcement).
);

--------------------------------------------------------------------------------
-- CLAIM_PAYMENT
--------------------------------------------------------------------------------
CREATE OR REPLACE TABLE claim_payment (
  payment_id       NUMBER(14)    NOT NULL DEFAULT seq_payment_id.NEXTVAL,
  claim_id         NUMBER(12)    NOT NULL,
  payment_date     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP NOT NULL,
  amount           NUMBER(14,2)  NOT NULL,
  payment_method   VARCHAR(16),
  check_number     VARCHAR(20),
  CONSTRAINT pk_payment PRIMARY KEY (payment_id),
  CONSTRAINT fk_payment_claim FOREIGN KEY (claim_id) REFERENCES claim (claim_id)
);

-- Indexes from the Oracle schema (ix_policy_customer, ix_claim_policy,
-- ix_claim_status, and the function-based ix_cust_upper_name) are intentionally
-- not migrated: Snowflake has no user indexes. If query pruning ever matters at
-- scale, add a clustering key, e.g.:
--   ALTER TABLE claim CLUSTER BY (policy_id);
