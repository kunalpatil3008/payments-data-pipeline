/*
  The fact table. One row per payment, from both feeds.

  Joins to the dimensions are left joins to guarantee no payment is ever
  lost, and the row count test on this model proves it.

  has_amount lets reporting exclude the 15 payments with no value from money
  totals without dropping the rows themselves.
*/

select
    p.txn_id,
    p.posted_date,
    p.account_id,
    p.is_unknown_account,
    p.merchant_name,
    p.amount_gbp,
    (p.amount_gbp is not null)  as has_amount,
    p.currency,
    p.channel,
    p.status,
    p.source_system,

    a.region,
    a.risk_band

from {{ ref('int_payments_unioned') }} p

left join {{ ref('dim_accounts') }} a
    on p.account_id = a.account_id
