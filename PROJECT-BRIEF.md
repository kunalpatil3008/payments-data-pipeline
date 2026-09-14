# Payment Reconciliation — Practice Project

A rebuild of the n-Gen work, on data messy enough to be real.

**Goal:** by the end you have a GitHub repo showing dbt models on Snowflake over multi-source payment feeds, with tests that catch real defects. That repo is the answer to "tell me about your dbt experience".

---

## The files

| File | Rows | What it is |
|---|---|---|
| `payments_source_a.csv` | 5,000 | Card acquirer feed. UK dates, mixed currency case, quoted commas. |
| `payments_source_b.csv` | 2,200 | Bank feed. ISO dates, different column names, **amounts in pence**. |
| `accounts.csv` | 120 | Account dimension. |
| `settlements.json` | 1,399 | Nested JSON, one object per line. For VARIANT. |
| `payments_raw.xlsx` | — | The three CSVs as one workbook, if you prefer starting in Excel. |

Two sources that describe the same thing differently is the whole point. That is what "multi source payment ingestion feeds" on your CV actually means.

---

## Defects planted on purpose

Do not look for these yet. Find them, then check the list.

| Defect | Count | What should catch it |
|---|---|---|
| Ambiguous UK dates (day ≤ 12) | ~300 | A date format check. This is the Klearway bug again. |
| Missing `gross_amount` | 40 | `not_null` test |
| Orphan `account_id` (no matching account) | 25 | `relationships` test |
| Duplicate `txn_id` | 18 | `unique` test, and a row count check around the join |
| Padded whitespace on `account_id` | 30 | Silent join failure. Nastiest one here. |
| Negative amounts on non-reversals | 12 | Singular test |
| Currency as `gbp` and `GBP` | many | Breaks a GROUP BY |
| Amounts in pence not pounds (source B) | all | Nothing catches this but reading the spec. Off by 100x. |

The whitespace and the pence are the two that would reach a report unnoticed. Those are the ones worth talking about in an interview.

---

## Week 1 — Snowflake only, no dbt

1. Create warehouse `WH_DEV`, size XS, auto-suspend 60.
2. Create database `PAYMENTS_DEV`, schemas `RAW`, `STAGING`, `MARTS`.
3. Create an internal stage. `PUT` the three CSVs into it. `LIST` to confirm.
4. Create a `FILE FORMAT` for CSV. Get the date format right. **It will fail first time.**
5. `COPY INTO` three raw tables. Use `ON_ERROR = 'CONTINUE'` first to see what fails, then fix the format and reload properly.
6. Load `settlements.json` into a single `VARIANT` column. Query `payload:amounts.gross::number` and `payload:account.id::string`.
7. Answer with SQL: how many rows failed to load, and why?
8. Drop a table. `UNDROP` it. Then query a table `AT (OFFSET => -300)`.
9. Clone `PAYMENTS_DEV` to `PAYMENTS_SANDBOX`. Time how long it takes.
10. Open Query History, then a query profile. Find partitions scanned versus total.
11. Admin → Usage. Look at what you spent.

**Stop here.** Do not start dbt until steps 1 to 11 are done.

---

## Week 2 — dbt on top

Models to build:

```
staging/
  stg_card_payments.sql      cast dates, TRIM account_id, UPPER currency
  stg_bank_payments.sql      rename columns, divide pence by 100
  stg_accounts.sql
  stg_settlements.sql        flatten the VARIANT fields you need
intermediate/
  int_payments_unioned.sql   both sources into one shape
marts/
  fct_payments.sql           1 fact
  dim_accounts.sql           conformed dimension
```

Tests to add:

- `unique` and `not_null` on `txn_id`
- `relationships` from payments to accounts
- `accepted_values` on currency and status
- A **singular** test: no negative amount unless status is `reversed`
- A **singular** test: row count of the joined model equals row count of the union

That last one is the fan-out check. It will fail because of the 18 duplicate `txn_id`s. Good. Fix it, and now you have a real story about catching silent fan out.

---

## Week 3 — finish it

- `dbt docs generate` and look at the lineage graph
- Write a README explaining the two sources, the defects, and what each test catches
- Push to GitHub as `payments-reconciliation-dbt`

---

## The questions this project lets you answer

1. Walk me through a dbt project you have built.
2. What is silent fan out and how did you catch it?
3. Why VARIANT instead of flattening?
4. Tell me about a data quality bug you found.
5. How do you handle two sources that describe the same thing differently?

You will be able to answer all five from something you built last week rather than something you half remember.
