-- Pulls the nested JSON apart into proper columns.
-- reason_codes stays as an array on purpose - it is a list, and flattening
-- it here would duplicate every settlement row.

select
    payload:settlement_id::string        as settlement_id,
    payload:batch.batch_date::date       as batch_date,
    payload:batch.processor::string      as processor,
    trim(payload:account.id::string)     as account_id,
    payload:account.risk_band::string    as risk_band,
    payload:amounts.gross::number(12,2)  as gross_gbp,
    payload:amounts.fees::number(12,2)   as fees_gbp,
    payload:reconciled::boolean          as is_reconciled,
    payload:reason_codes                 as reason_codes

from {{ source('raw', 'raw_settlements') }}
