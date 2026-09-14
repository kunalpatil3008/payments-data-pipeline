/*
  Card acquirer feed, cleaned.

  DECISION - duplicate txn_id
  The source sends 18 transaction references twice. A transaction ID must be
  unique, so leaving them would multiply rows on every downstream join and
  inflate the money totals. Wrong numbers get fixed.

  Kept the first occurrence of each, ordered by posted_date then amount so
  the choice is deterministic rather than whatever Snowflake returns first.
  The dropped rows are recoverable from RAW at any time.

  DECISION - orphan account_id
  25 payments point at accounts that are not in the account list. These are
  real payments carrying real money. Dropping them would make the
  reconciliation quietly incomplete, which is worse than visibly wrong, so
  they are kept and labelled 'UNKNOWN'. The test is set to warn, not error.
*/

with source as (

    select * from {{ source('raw', 'raw_card_payments') }}

),

deduped as (

    select
        *,
        row_number() over (
            partition by txn_id
            order by posted_date, gross_amount
        ) as rn
    from source

),

cleaned as (

    select
        txn_id,
        posted_date,
        trim(account_id)  as account_id,
        merchant_name,
        gross_amount      as amount_gbp,
        upper(currency)   as currency,
        channel,
        status
    from deduped
    where rn = 1                      -- keep first of each txn_id

)

select
    c.txn_id,
    c.posted_date,

    -- label rather than lose: an account we cannot match is still a payment
    coalesce(a.account_id, 'UNKNOWN') as account_id,
    (a.account_id is null)            as is_unknown_account,

    c.merchant_name,
    c.amount_gbp,
    c.currency,
    c.channel,
    c.status

from cleaned c
left join {{ ref('stg_accounts') }} a
    on c.account_id = a.account_id
