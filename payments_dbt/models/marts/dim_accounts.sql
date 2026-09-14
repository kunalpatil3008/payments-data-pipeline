/*
  Account dimension. One row per account, plus an UNKNOWN row so that
  payments with an unmatched account still join to something instead of
  disappearing from the report.
*/

select
    account_id,
    account_name,
    region,
    risk_band,
    opened_date
from {{ ref('stg_accounts') }}

union all

select
    'UNKNOWN'   as account_id,
    'Unmatched account' as account_name,
    'Unknown'   as region,
    'Unknown'   as risk_band,
    null        as opened_date
