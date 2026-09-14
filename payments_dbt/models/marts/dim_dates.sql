/*
  Date dimension covering the period the payments span.
  Lets Power BI group by month, quarter or weekday without writing date
  logic in every measure.
*/

with bounds as (
    select
        min(posted_date) as min_d,
        max(posted_date) as max_d
    from {{ ref('int_payments_unioned') }}
),

days as (
    select
        dateadd(day, seq4(), (select min_d from bounds)) as date_day
    from table(generator(rowcount => 1000))
)

select
    date_day,
    year(date_day)                   as year,
    quarter(date_day)                as quarter,
    month(date_day)                  as month,
    monthname(date_day)              as month_name,
    dayofweek(date_day)              as day_of_week,
    dayname(date_day)                as day_name,
    date_trunc('month', date_day)    as month_start,
    (date_day > '2026-03-31')        as is_outside_q1
from days
where date_day <= (select max_d from bounds)
