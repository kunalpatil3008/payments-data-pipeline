/*
  One row per settlement, with how long it has been outstanding.

  Ageing is measured from the batch date to the latest batch date in the
  data, so the buckets stay meaningful without depending on today's date.

  Ageing buckets (0-7, 8-30, 31+) turn a flat list of 330 failures into a
  worklist someone can actually work through, oldest and largest first.

  reason_codes is left as an array here. It is flattened in a separate model
  because one settlement can carry several codes, and flattening at this
  grain would duplicate the money.
*/

with settlements as (

    select * from {{ ref('stg_settlements') }}

),

reference_date as (

    select max(batch_date) as as_at_date from settlements

)

select
    s.settlement_id,
    s.batch_date,
    s.processor,
    s.account_id,
    s.risk_band,
    s.gross_gbp,
    s.fees_gbp,
    s.is_reconciled,
    s.reason_codes,

    datediff(day, s.batch_date, r.as_at_date) as days_outstanding,

    case
        when s.is_reconciled then 'Reconciled'
        when datediff(day, s.batch_date, r.as_at_date) <= 7  then '0-7 days'
        when datediff(day, s.batch_date, r.as_at_date) <= 30 then '8-30 days'
        else '31+ days'
    end as ageing_bucket,

    -- flags the contradiction found in analysis: tagged OK yet not reconciled
    (not s.is_reconciled
     and array_contains('OK'::variant, s.reason_codes)) as is_contradictory

from settlements s
cross join reference_date r
