/* ============================================================================
   PAYMENT RECONCILIATION PIPELINE - SNOWFLAKE SETUP
   ----------------------------------------------------------------------------
   Two systems record the same money and disagree:
     - a card acquirer feed  (5,000 rows, UK dates, amounts in pounds)
     - a bank feed           (2,200 rows, ISO dates, amounts in PENCE)
     - an account dimension  (120 rows)
     - settlement records    (1,399 nested JSON objects)

   Question: a quarter of settlements do not reconcile. Which accounts,
   what reasons, how much money, and who should chase what first?

   Principle: RAW holds exactly what the source sent. Nothing is cleaned
   on the way in. Every fix happens later, in code you can read.
   ============================================================================ */


/* ============================================================================
   01. SETUP - engine and filing
   ----------------------------------------------------------------------------
   A warehouse is compute, not storage. It bills per second while running,
   so AUTO_SUSPEND is the single most important setting here.
   ============================================================================ */

CREATE WAREHOUSE IF NOT EXISTS WH_DEV
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND   = 60          -- switch off after 60s idle
  AUTO_RESUME    = TRUE;       -- switch back on when a query arrives

CREATE DATABASE IF NOT EXISTS PAYMENTS_DEV;
CREATE SCHEMA   IF NOT EXISTS PAYMENTS_DEV.RAW;

USE WAREHOUSE WH_DEV;
USE SCHEMA PAYMENTS_DEV.RAW;

-- session context check: which engine, which database, which schema
SELECT CURRENT_WAREHOUSE(), CURRENT_DATABASE(), CURRENT_SCHEMA();


/* ============================================================================
   02. FILE FORMAT AND STAGE
   ----------------------------------------------------------------------------
   A file format tells Snowflake how the CSV is written. This object is where
   most loading bugs live.

   Two deliberate choices:
     FIELD_OPTIONALLY_ENCLOSED_BY  handles "Wembley Tyres, Ltd"
     DATE_FORMAT = 'DD/MM/YYYY'    nothing in the file says which way round
                                   the dates are - this is us deciding

   TRIM_SPACE = FALSE is also deliberate. Padded account IDs must survive
   into RAW so we can see and fix them, not be silently tidied on load.
   ============================================================================ */

CREATE OR REPLACE FILE FORMAT FF_CSV
  TYPE = CSV
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  DATE_FORMAT = 'DD/MM/YYYY'
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = FALSE
  NULL_IF = ('', 'NULL', 'null');

-- a stage is a shelf: files sit here as files, before becoming rows
CREATE OR REPLACE STAGE RAW_STAGE
  FILE_FORMAT = FF_CSV;

-- files are uploaded via the UI (Catalog > RAW > Stages > RAW_STAGE > + Files)
-- because PUT needs the SnowSQL CLI and does not work from a browser
LIST @RAW_STAGE;   -- expect 4 files


/* ============================================================================
   03. LOAD CARD PAYMENTS
   ----------------------------------------------------------------------------
   Typed columns on purpose. DATE and NUMBER mean bad values fail loudly
   instead of sliding in as text.

   ON_ERROR = 'CONTINUE' skips bad rows and loads the rest, so a first load
   shows you everything that breaks rather than stopping at the first problem.
   In production you would want it to stop.
   ============================================================================ */

CREATE OR REPLACE TABLE RAW_CARD_PAYMENTS (
  txn_id        VARCHAR,
  posted_date   DATE,
  account_id    VARCHAR,
  merchant_name VARCHAR,
  gross_amount  NUMBER(12,2),
  currency      VARCHAR,
  channel       VARCHAR,
  status        VARCHAR
);

COPY INTO RAW_CARD_PAYMENTS
FROM @RAW_STAGE
PATTERN = '.*payments_source_a.*'
FILE_FORMAT = (FORMAT_NAME = FF_CSV)
ON_ERROR = 'CONTINUE';

-- VALIDATE shows EVERY rejected row with the reason.
-- The COPY result only shows the first error.
SELECT * FROM TABLE(VALIDATE(RAW_CARD_PAYMENTS, JOB_ID => '_last'));


/* ============================================================================
   04. LOAD BANK PAYMENTS AND ACCOUNTS
   ----------------------------------------------------------------------------
   Source B is the same business event described differently:
     - dates are ISO, so the format is overridden inline
     - AMOUNT_MINOR_UNITS is in PENCE, not pounds

   Nothing in the data warns you about the pence. Only the column name does.
   Add these to the card amounts without dividing by 100 and every total is
   100x wrong, with no error anywhere. Fixed later, in dbt.
   ============================================================================ */

CREATE OR REPLACE TABLE RAW_BANK_PAYMENTS (
  transaction_reference VARCHAR,
  value_date            DATE,
  customer_account      VARCHAR,
  counterparty          VARCHAR,
  amount_minor_units    NUMBER(18,0),   -- PENCE
  currency_code         VARCHAR,
  transaction_type      VARCHAR,
  settlement_status     VARCHAR
);

COPY INTO RAW_BANK_PAYMENTS
FROM @RAW_STAGE
PATTERN = '.*payments_source_b.*'
FILE_FORMAT = (FORMAT_NAME = FF_CSV, DATE_FORMAT = 'YYYY-MM-DD')
ON_ERROR = 'CONTINUE';

CREATE OR REPLACE TABLE RAW_ACCOUNTS (
  account_id   VARCHAR,
  account_name VARCHAR,
  region       VARCHAR,
  opened_date  DATE,
  risk_band    VARCHAR
);

COPY INTO RAW_ACCOUNTS
FROM @RAW_STAGE
PATTERN = '.*accounts.*'
FILE_FORMAT = (FORMAT_NAME = FF_CSV)
ON_ERROR = 'CONTINUE';


/* ============================================================================
   05. LOAD SETTLEMENTS (nested JSON)
   ----------------------------------------------------------------------------
   One VARIANT column holds the whole object. We do not flatten on load,
   because flattening 40 fields to read 3 costs compute every load, and a
   new field at source would break the pipeline.
   ============================================================================ */

CREATE OR REPLACE FILE FORMAT FF_JSON
  TYPE = JSON
  STRIP_OUTER_ARRAY = FALSE;   -- one object per line, not one big array

CREATE OR REPLACE TABLE RAW_SETTLEMENTS (payload VARIANT);

COPY INTO RAW_SETTLEMENTS
FROM @RAW_STAGE
PATTERN = '.*settlements.*'
FILE_FORMAT = (FORMAT_NAME = FF_JSON)
ON_ERROR = 'CONTINUE';

-- see the shape before querying it
SELECT payload FROM RAW_SETTLEMENTS LIMIT 1;

-- reading inside a VARIANT:
--   :   goes into the object
--   .   goes deeper
--   ::  casts to a real type - ALWAYS cast, or comparisons behave oddly
SELECT
  payload:settlement_id::STRING       AS settlement_id,
  payload:batch.batch_date::DATE      AS batch_date,
  payload:batch.processor::STRING     AS processor,
  payload:account.id::STRING          AS account_id,
  payload:amounts.gross::NUMBER(12,2) AS gross,
  payload:amounts.fees::NUMBER(12,2)  AS fees,
  payload:reconciled::BOOLEAN         AS reconciled
FROM RAW_SETTLEMENTS
LIMIT 10;


/* ============================================================================
   06. DATA QUALITY - the important section
   ----------------------------------------------------------------------------
   The load returned ZERO errors. The data is still wrong in ten ways.

   A successful load proves the file was readable. It proves nothing about
   whether the data is correct. Loading and validation are separate jobs and
   only the first one gives you an error message.

   Checks 4 to 10 are EXPECTED to find problems. If they ever return zero,
   something has cleaned RAW, which is what we do not want.
   ============================================================================ */

WITH checks AS (
  SELECT 1 AS ord, 'card rows' AS check_name,
         (SELECT COUNT(*) FROM RAW_CARD_PAYMENTS)::STRING AS actual,
         '5000' AS expected
  UNION ALL SELECT 2, 'bank rows',
         (SELECT COUNT(*) FROM RAW_BANK_PAYMENTS)::STRING, '2200'
  UNION ALL SELECT 3, 'account rows',
         (SELECT COUNT(*) FROM RAW_ACCOUNTS)::STRING, '120'
  UNION ALL SELECT 4, 'settlement rows',
         (SELECT COUNT(*) FROM RAW_SETTLEMENTS)::STRING, '1399'
  UNION ALL SELECT 5, 'currency spellings',
         (SELECT COUNT(DISTINCT currency)::STRING FROM RAW_CARD_PAYMENTS),
         '4 - GBP and gbp are the same currency'
  UNION ALL SELECT 6, 'padded account_ids',
         (SELECT COUNT(*)::STRING FROM RAW_CARD_PAYMENTS
          WHERE account_id <> TRIM(account_id)),
         '30 - invisible spaces, will not join'
  UNION ALL SELECT 7, 'orphan accounts',
         (SELECT COUNT(*)::STRING FROM RAW_CARD_PAYMENTS c
          WHERE NOT EXISTS (SELECT 1 FROM RAW_ACCOUNTS a
                            WHERE a.account_id = TRIM(c.account_id))),
         '25 - account does not exist'
  UNION ALL SELECT 8, 'duplicate txn_ids',
         (SELECT COUNT(*)::STRING FROM (
            SELECT txn_id FROM RAW_CARD_PAYMENTS
            GROUP BY txn_id HAVING COUNT(*) > 1)),
         '18 - will cause fan out on join'
  UNION ALL SELECT 9, 'bad negatives',
         (SELECT COUNT(*)::STRING FROM RAW_CARD_PAYMENTS
          WHERE gross_amount < 0 AND status <> 'reversed'),
         '12 - negative on a non-reversal'
  UNION ALL SELECT 10, 'out of range dates',
         (SELECT COUNT(*)::STRING FROM RAW_CARD_PAYMENTS
          WHERE posted_date > '2026-03-31'),
         '230 - Q1 file with dates later in the year'
)
SELECT check_name, actual, expected FROM checks ORDER BY ord;

-- currency: one currency, two spellings, so any GROUP BY splits it
SELECT currency, COUNT(*) AS n
FROM RAW_CARD_PAYMENTS GROUP BY currency ORDER BY n DESC;

-- where the out of range dates sit
SELECT DATE_TRUNC('month', posted_date) AS mth, COUNT(*) AS n
FROM RAW_CARD_PAYMENTS GROUP BY 1 ORDER BY 1;


/* ============================================================================
   07. ANALYSIS - how big is the problem
   ============================================================================ */

-- headline: how many settlements fail
SELECT
  COUNT(*) AS total_settlements,
  SUM(IFF(payload:reconciled::BOOLEAN = FALSE, 1, 0)) AS unreconciled,
  ROUND(100.0 * SUM(IFF(payload:reconciled::BOOLEAN = FALSE, 1, 0))
        / COUNT(*), 1) AS pct
FROM RAW_SETTLEMENTS;
-- result: 1,399 total, 330 unreconciled, 23.6%

-- turn the rate into money - this is the number people act on
SELECT
  COUNT(*) AS n,
  ROUND(SUM(payload:amounts.gross::NUMBER(12,2)), 2) AS gbp_unreconciled
FROM RAW_SETTLEMENTS
WHERE payload:reconciled::BOOLEAN = FALSE;
-- result: GBP 187,909.88 stuck


/* ============================================================================
   08. ANALYSIS - three hypotheses, all rejected
   ============================================================================ */

/* H1: is one processor worse than the others?
   Result: Adyen 21.8%, Stripe 23.9%, Barclaycard 25.2%
   A 3.4 point spread on ~470 settlements each. z = 1.21, needs ~1.96.
   REJECTED - that is noise, not a bad processor. */
SELECT
  payload:batch.processor::STRING AS processor,
  COUNT(*) AS total,
  SUM(IFF(payload:reconciled::BOOLEAN = FALSE, 1, 0)) AS failed,
  ROUND(100.0 * SUM(IFF(payload:reconciled::BOOLEAN = FALSE, 1, 0))
        / COUNT(*), 1) AS fail_pct
FROM RAW_SETTLEMENTS
GROUP BY 1
ORDER BY fail_pct DESC;

/* H2: is the money concentrated in a few bad accounts?
   Result: 108 accounts hold the GBP 188k. Top 5 = 12.5%, top 20 = 41%.
   Biggest single account = 2.8%.
   REJECTED - no account is the problem. */
SELECT
  payload:account.id::STRING        AS account_id,
  payload:account.risk_band::STRING AS risk_band,
  COUNT(*) AS failed_settlements,
  ROUND(SUM(payload:amounts.gross::NUMBER(12,2)), 2) AS gbp_stuck
FROM RAW_SETTLEMENTS
WHERE payload:reconciled::BOOLEAN = FALSE
GROUP BY 1, 2
ORDER BY gbp_stuck DESC
LIMIT 20;

/* H3: does one reason code dominate the failures?
   FLATTEN turns a list inside one row into several rows, one per item,
   so a list can be grouped and counted. */
SELECT
  f.value::STRING AS reason_code,
  COUNT(*) AS n,
  ROUND(SUM(payload:amounts.gross::NUMBER(12,2)), 2) AS gbp
FROM RAW_SETTLEMENTS,
     LATERAL FLATTEN(input => payload:reason_codes) f
WHERE payload:reconciled::BOOLEAN = FALSE
GROUP BY 1
ORDER BY gbp DESC;

/* The step almost everyone skips: compare against the base rate.
   Every code appears on ~40% of FAILED and ~40% of RECONCILED settlements.
   REJECTED - the codes cannot discriminate, so they carry no information.

   Never judge a field by looking only at the group you care about.
   Always ask: compared to what? */
SELECT
  payload:reconciled::BOOLEAN AS reconciled,
  f.value::STRING AS reason_code,
  COUNT(*) AS n,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY payload:reconciled::BOOLEAN), 1) AS pct_of_group
FROM RAW_SETTLEMENTS,
     LATERAL FLATTEN(input => payload:reason_codes) f
GROUP BY 1, 2
ORDER BY 1, 2;

/* A contradiction worth reporting on its own:
   123 settlements are tagged OK and did NOT reconcile - GBP 69,904.
   A field that contradicts itself on 37% of cases cannot be built on. */
SELECT
  COUNT(*) AS tagged_ok_but_failed,
  ROUND(SUM(payload:amounts.gross::NUMBER(12,2)), 2) AS gbp
FROM RAW_SETTLEMENTS
WHERE payload:reconciled::BOOLEAN = FALSE
  AND ARRAY_CONTAINS('OK'::VARIANT, payload:reason_codes);

/* CONCLUSION
   GBP 187,909.88 unreconciled across 108 accounts. No processor pattern,
   no account concentration, no dominant reason. The failures look systemic,
   and the reason code field contradicts itself on 37% of cases.
   Recommendation: fix reason codes at source. Until they mean something,
   nobody can prioritise this queue. */


/* ============================================================================
   09. TIME TRAVEL
   ----------------------------------------------------------------------------
   Snowflake keeps previous versions of a table. Standard edition: 1 day.
   Enterprise and above: up to 90 days, set per table.
   ============================================================================ */

SELECT COUNT(*) FROM RAW_ACCOUNTS;                        -- 120

DELETE FROM RAW_ACCOUNTS WHERE region = 'Scotland';       -- break it
SELECT COUNT(*) FROM RAW_ACCOUNTS;                        -- fewer

SELECT COUNT(*) FROM RAW_ACCOUNTS AT (OFFSET => -300);    -- 5 mins ago: 120

CREATE OR REPLACE TABLE RAW_ACCOUNTS AS                   -- put it back
SELECT * FROM RAW_ACCOUNTS AT (OFFSET => -300);

SELECT COUNT(*) FROM RAW_ACCOUNTS;                        -- 120 again


/* ============================================================================
   10. ZERO-COPY CLONE
   ----------------------------------------------------------------------------
   Instant, and costs no storage, because it points at the same underlying
   files until something changes. This is how teams get a full-size dev
   environment for free.
   ============================================================================ */

USE ROLE ACCOUNTADMIN;

CREATE DATABASE PAYMENTS_SANDBOX CLONE PAYMENTS_DEV;

SELECT COUNT(*) FROM PAYMENTS_SANDBOX.RAW.RAW_CARD_PAYMENTS;  -- 5000
SELECT COUNT(*) FROM PAYMENTS_SANDBOX.RAW.RAW_SETTLEMENTS;    -- 1399


/* ============================================================================
   11. ROLES AND GRANTS - least privilege for dbt
   ----------------------------------------------------------------------------
   dbt should never run as ACCOUNTADMIN. It reads RAW and writes STAGING and
   MARTS. It must not be able to modify RAW.

   GRANT ... ON FUTURE TABLES means tables created tomorrow are covered
   automatically. Without it, permissions rot as new tables appear.
   ============================================================================ */

USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS TRANSFORMER;

-- an engine
GRANT USAGE ON WAREHOUSE WH_DEV TO ROLE TRANSFORMER;

-- read RAW, and only read
GRANT USAGE  ON DATABASE PAYMENTS_DEV        TO ROLE TRANSFORMER;
GRANT USAGE  ON SCHEMA   PAYMENTS_DEV.RAW    TO ROLE TRANSFORMER;
GRANT SELECT ON ALL TABLES    IN SCHEMA PAYMENTS_DEV.RAW TO ROLE TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA PAYMENTS_DEV.RAW TO ROLE TRANSFORMER;

-- somewhere to write
CREATE SCHEMA IF NOT EXISTS PAYMENTS_DEV.STAGING;
CREATE SCHEMA IF NOT EXISTS PAYMENTS_DEV.MARTS;
GRANT ALL ON SCHEMA PAYMENTS_DEV.STAGING TO ROLE TRANSFORMER;
GRANT ALL ON SCHEMA PAYMENTS_DEV.MARTS   TO ROLE TRANSFORMER;
GRANT CREATE SCHEMA ON DATABASE PAYMENTS_DEV TO ROLE TRANSFORMER;

GRANT ROLE TRANSFORMER TO USER KUNAL3008;


/* ---- prove least privilege actually works -------------------------------- */

USE ROLE TRANSFORMER;
USE WAREHOUSE WH_DEV;

-- works: reading RAW
SELECT COUNT(*) FROM PAYMENTS_DEV.RAW.RAW_CARD_PAYMENTS;

-- works: writing to STAGING
CREATE OR REPLACE TABLE PAYMENTS_DEV.STAGING.PERMISSION_TEST AS SELECT 1 AS x;
DROP TABLE PAYMENTS_DEV.STAGING.PERMISSION_TEST;

-- MUST FAIL: writing to RAW
-- expected: "Insufficient privileges to operate on schema 'RAW'.
--            Your primary role TRANSFORMER must have CREATE TABLE granted"
-- A permission error always names three things: the role, the object,
-- and the missing privilege. It writes the fix for you.
CREATE TABLE PAYMENTS_DEV.RAW.SHOULD_NOT_WORK AS SELECT 1 AS x;

USE ROLE ACCOUNTADMIN;


/* ============================================================================
   NEXT: dbt
   ----------------------------------------------------------------------------
   Nothing above has reconciled anything. The two payment sources are still
   in separate tables. Still to do, in dbt:
     - trim the whitespace, standardise the currency, divide the pence by 100
     - union the two sources into one shape
     - build a star schema: 1 fact, conformed dimensions
     - tests: unique, not_null, relationships, accepted_values
     - a row count check around the join, which WILL fail on the 18 duplicate
       txn_ids - that is silent fan out, caught before it reaches a report
   ============================================================================ */
