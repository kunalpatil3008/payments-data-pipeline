/*
  One row per settlement PER reason code.

  Separate from fct_settlements on purpose. A settlement can carry three
  codes, so counting money on this table would treble it. Use this table to
  count reasons, and fct_settlements to count money.
*/

select
    s.settlement_id,
    s.batch_date,
    s.account_id,
    s.is_reconciled,
    s.ageing_bucket,
    s.gross_gbp,
    f.value::string as reason_code

from {{ ref('fct_settlements') }} s,
     lateral flatten(input => s.reason_codes) f
