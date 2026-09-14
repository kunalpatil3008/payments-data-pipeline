-- The bank feed describes the same events as the card feed, differently.
-- This model gives it the SAME SHAPE as stg_card_payments so the two can
-- be stacked together later.
--
-- The important line is the amount. The source stores PENCE. Every column
-- here is renamed to match the card model, so after this point one name
-- means one thing.
--
-- DECISION: settlement_status does not map cleanly onto the card statuses.
-- Nobody documented what RETURNED means. Mapped to 'failed'. Needs
-- confirming with the source system owner.

select
    transaction_reference       as txn_id,
    value_date                  as posted_date,
    trim(customer_account)      as account_id,
    counterparty                as merchant_name,
    amount_minor_units / 100.0  as amount_gbp,      -- pence -> pounds
    upper(currency_code)        as currency,
    lower(transaction_type)     as channel,

    case
        when settlement_status = 'SETTLED'   then 'settled'
        when settlement_status = 'UNSETTLED' then 'pending'
        when settlement_status = 'RETURNED'  then 'failed'
    end                         as status

from {{ source('raw', 'raw_bank_payments') }}
