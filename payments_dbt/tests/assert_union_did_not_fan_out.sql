/*
  Singular test.

  A singular test is a query that returns the rows that SHOULD NOT EXIST.
  Return nothing and it passes. Return anything and it fails.

  This one asserts that stacking the two feeds produced exactly as many rows
  as the two feeds contain. If a join or union ever starts multiplying rows,
  this fails immediately instead of quietly inflating every money total
  downstream. That is silent fan out, and it is the defect that does the
  most damage because nothing errors.

  It passes today because the duplicate txn_ids were removed in staging.
  Keeping it means that fix can never be undone by accident.
*/

with counts as (

    select
        (select count(*) from {{ ref('int_payments_unioned') }}) as union_rows,
        (select count(*) from {{ ref('stg_card_payments') }})
      + (select count(*) from {{ ref('stg_bank_payments') }})    as source_rows

)

select *
from counts
where union_rows <> source_rows
