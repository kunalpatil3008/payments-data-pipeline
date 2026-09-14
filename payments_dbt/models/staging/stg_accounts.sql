-- One row per account. Almost nothing to fix here except the padding.

select
    trim(account_id)  as account_id,
    account_name,
    region,
    opened_date,
    risk_band

from {{ source('raw', 'raw_accounts') }}
