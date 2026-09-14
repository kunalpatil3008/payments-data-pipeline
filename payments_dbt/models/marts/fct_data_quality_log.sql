/*
  The data quality register, calculated live.

  Every known defect in the source data, how many rows it affects, what was
  decided about it, and whether that decision is a fix or something we are
  living with.

  This is deliberately a MODEL and not a hand-typed table. A typed list is
  correct on the day it is written and wrong a month later. These counts come
  from the data itself, so the page can never quietly drift out of date.

  status values:
    Fixed      - corrected in the pipeline, cannot reach reporting
    Accepted   - known, deliberately kept, documented
    Escalated  - source system problem, raised, not ours to fix
    Open       - under investigation
*/

with

duplicate_txn_ids as (
    select count(*) as n
    from (
        select txn_id
        from {{ source('raw', 'raw_card_payments') }}
        group by txn_id
        having count(*) > 1
    )
),

lowercase_currency as (
    select count(*) as n
    from {{ source('raw', 'raw_card_payments') }}
    where currency <> upper(currency)
),

padded_account_ids as (
    select count(*) as n
    from {{ source('raw', 'raw_card_payments') }}
    where account_id <> trim(account_id)
),

unmatched_accounts as (
    select count(*) as n
    from {{ ref('fct_payments') }}
    where is_unknown_account
),

missing_amounts as (
    select count(*) as n
    from {{ ref('fct_payments') }}
    where not has_amount
),

out_of_range_dates as (
    select count(*) as n
    from {{ ref('fct_payments') }}
    where posted_date > '2026-03-31'
),

contradictory as (
    select
        count(*)        as n,
        sum(gross_gbp)  as gbp
    from {{ ref('fct_settlements') }}
    where is_contradictory
)

select 1 as sort_order,
       'Duplicate transaction IDs'                as issue,
       'Source sends the same reference twice'    as detail,
       (select n from duplicate_txn_ids)          as row_count,
       cast(null as number(12,2))                 as gbp_value,
       'Removed, kept first of each'              as decision,
       'Duplicates inflate money totals on every join. Wrong numbers get fixed.' as rationale,
       'Fixed'                                    as status

union all
select 2,
       'Currency recorded in mixed case',
       'Same currency stored as GBP and gbp',
       (select n from lowercase_currency),
       null,
       'Standardised to upper case',
       'A GROUP BY would otherwise split one currency into two.',
       'Fixed'

union all
select 3,
       'Account IDs with trailing spaces',
       'Invisible padding on the reference',
       (select n from padded_account_ids),
       null,
       'Trimmed in staging',
       'Would not match the account list. Rows vanish from joins with no error.',
       'Fixed'

union all
select 4,
       'Payments with an unmatched account',
       'Account reference does not exist',
       (select n from unmatched_accounts),
       null,
       'Kept, labelled UNKNOWN',
       'Real payments carrying real money. Dropping them makes the answer quietly incomplete.',
       'Accepted'

union all
select 5,
       'Bank payments with no amount',
       'Source sends the row with an empty value',
       (select n from missing_amounts),
       null,
       'Kept, excluded from money totals',
       'The payment happened, the value is unknown. A missing amount is not an amount of nothing.',
       'Accepted'

union all
select 6,
       'Settlements tagged OK but not reconciled',
       'The source contradicts itself',
       (select n from contradictory),
       (select gbp from contradictory),
       'Flagged, raised with source owner',
       'A field that disagrees with itself on a third of cases cannot be used to prioritise.',
       'Escalated'

union all
select 7,
       'Payments dated outside Q1',
       'Dates later in the year in a Q1 file',
       (select n from out_of_range_dates),
       null,
       'Under investigation',
       'Either a source error or the file covers more than stated. Not yet confirmed.',
       'Open'

order by sort_order
