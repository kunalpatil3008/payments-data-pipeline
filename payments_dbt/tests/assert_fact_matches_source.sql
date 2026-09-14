/*
  The fact table must contain exactly as many rows as the unioned source.
  If a dimension join ever starts multiplying rows, this fails before the
  inflated numbers reach a report.
*/

with counts as (
    select
        (select count(*) from {{ ref('fct_payments') }})         as fact_rows,
        (select count(*) from {{ ref('int_payments_unioned') }}) as source_rows
)

select * from counts
where fact_rows <> source_rows
