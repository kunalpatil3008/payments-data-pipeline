/*
  The two payment feeds, stacked into one table.

  Both staging models were deliberately given the same column names and the
  same units, so this is a plain union rather than a mapping exercise. That
  work was done upstream on purpose - a union that needs renaming is a sign
  the staging layer did not finish its job.

  source_system is added so every row can be traced back to where it came
  from. Without it, the moment the two feeds disagree you cannot tell which
  one is which.
*/

with card as (

    select
        txn_id,
        posted_date,
        account_id,
        is_unknown_account,
        merchant_name,
        amount_gbp,
        currency,
        channel,
        status,
        'card_acquirer' as source_system
    from {{ ref('stg_card_payments') }}

),

bank as (

    select
        txn_id,
        posted_date,
        account_id,
        false            as is_unknown_account,
        merchant_name,
        amount_gbp,
        currency,
        channel,
        status,
        'bank_feed'      as source_system
    from {{ ref('stg_bank_payments') }}

)

select * from card
union all
select * from bank
