-- =====================================================================
-- 09_labor.sql — 設定表 + 逐時段逐星期的出杯量（人力估算用）
--
-- 「一天要幾個人」= 每個小時要出幾杯 ÷ 一個人一小時能出幾杯。
-- 左邊資料庫已經知道（訂單有付款時間）；右邊只有店裡自己知道，
-- 所以是設定值，不是猜的 —— 猜一個寫死在程式裡，算出來的班表
-- 就沒有人敢照著排。
--
-- 設定放資料庫不是 localStorage：換手機、換平板不能重設一次，
-- 而且店長改過的數字要讓下一個人看得到。
--
-- 部署：在 08_orders.sql 之後跑。可重複執行。
-- =====================================================================

create table if not exists erp_settings (
  key        text primary key,
  value      jsonb not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

alter table erp_settings enable row level security;
alter table erp_settings force  row level security;
revoke all on erp_settings from anon, authenticated;

-- 預設值：一個人一小時 45 杯是含收銀、封膜、洗杯的實際節奏，
-- 不是純出杯速度。店長按實際情況調。
insert into erp_settings (key, value) values
  ('labor', '{"cups_per_hour":45,"min_staff":1,"wage":200,"current_week_hours":0}'::jsonb)
on conflict (key) do nothing;

-- 權限檢查要獨立一行。寫成 where erp_require_staff() is not null 的話，
-- 表是空的時候那個 where 根本不會被評估，等於沒檢查。
create or replace function erp_get_settings()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform erp_require_staff();
  return (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from erp_settings);
end $$;

create or replace function erp_set_setting(p_key text, p_value jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := erp_require_manager();
begin
  insert into erp_settings (key, value, updated_by, updated_at)
  values (p_key, p_value, uid, now())
  on conflict (key) do update set
    value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('ok', true, 'key', p_key, 'value', p_value);
end $$;

revoke all on function erp_get_settings()             from public, anon;
revoke all on function erp_set_setting(text, jsonb)   from public, anon;
grant execute on function erp_get_settings()           to authenticated;
grant execute on function erp_set_setting(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- erp_order_analytics 多回傳 hours_dow：星期幾 × 幾點 的日均出杯量。
-- 排班是按星期排的，只有「全部日子平均」排不出班 ——
-- 星期六中午和星期三中午差很多，用同一個平均值兩邊都會錯。
-- ---------------------------------------------------------------------
drop function if exists erp_order_analytics(int);

create or replace function erp_order_analytics(p_months int default 6)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  d_to   date := erp_today();
  d_from date;
  v_out  jsonb;
begin
  perform erp_require_manager();
  d_from := (date_trunc('month', d_to)
             - ((greatest(coalesce(p_months, 6), 2) - 1) * interval '1 month'))::date;

  with
  o as (select * from erp_pos_orders where sales_on >= d_from),
  /* 每張單買了幾件、有沒有買周邊。
     「有買周邊的單值多少」是這頁最有用的一個數字 —— 有具體差額，
     才說得動店員在結帳時開口。 */
  li as (
    select s.sales_on, s.order_no,
           sum(s.qty) as n_items,
           bool_or(m.category = '周邊') as has_mds,
           sum(s.qty) filter (where coalesce(m.category,'') not in ('周邊','袋子')) as n_drinks
    from erp_pos_sales s
    left join erp_pos_item_map m on m.pos_name = s.pos_name
    where s.sales_on >= d_from
    group by 1, 2
  ),
  ob as (
    select o.sales_on, o.order_no, o.total, o.paid_at,
           coalesce(li.n_items, o.items)  as n_items,
           coalesce(li.n_drinks, o.items) as n_drinks,
           coalesce(li.has_mds, false)    as has_mds
    from o left join li on li.sales_on = o.sales_on and li.order_no = o.order_no
  ),
  -- 有付款時間的營業日數。時段的「日均」要除這個，不是除有那小時的天數
  hd as (select count(distinct sales_on) as n from o where paid_at is not null),
  dd as (
    select extract(dow from sales_on)::int as dw, count(distinct sales_on) as n
    from o where paid_at is not null group by 1
  ),
  hrs as (
    select extract(hour from paid_at)::int as h,
           count(*)     as orders,
           sum(total)   as amount,
           sum(n_items) as items,
           sum(n_drinks) as drinks
    from ob where paid_at is not null
    group by 1
  ),
  hdow as (
    select extract(dow from sales_on)::int  as dw,
           extract(hour from paid_at)::int  as h,
           count(*)      as orders,
           sum(n_drinks) as drinks,
           sum(n_items)  as items
    from ob where paid_at is not null
    group by 1, 2
  ),
  bands as (
    select case
             when total <  50 then '未滿 $50'
             when total < 100 then '$50–99'
             when total < 150 then '$100–149'
             when total < 200 then '$150–199'
             when total < 300 then '$200–299'
             when total < 500 then '$300–499'
             else '$500 以上'
           end as band,
           case
             when total <  50 then 1 when total < 100 then 2
             when total < 150 then 3 when total < 200 then 4
             when total < 300 then 5 when total < 500 then 6 else 7
           end as ord,
           count(*) as orders, sum(total) as amount
    from ob group by 1, 2
  ),
  sizes as (
    select least(ceil(n_items)::int, 6) as n,   -- 6 代表「6 件以上」
           count(*) as orders, sum(total) as amount
    from ob where n_items > 0 group by 1
  )
  select jsonb_build_object(
    'from', d_from, 'to', d_to,
    'days',       (select n from hd),
    'orders',     (select count(*) from ob),
    'with_time',  (select count(*) from ob where paid_at is not null),
    'avg_total',  (select round(avg(total)) from ob),
    'avg_items',  (select round(avg(n_items), 2) from ob where n_items > 0),
    'hours', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'h', h, 'orders', orders, 'amount', amount, 'items', items,
        'per_day',      round(orders::numeric / greatest((select n from hd), 1), 1),
        'cups_per_day', round(drinks          / greatest((select n from hd), 1), 1),
        'amt_per_day',  round(amount          / greatest((select n from hd), 1))
      ) order by h), '[]'::jsonb) from hrs),
    -- 排班用：星期幾 × 幾點 的日均杯數
    'hours_dow', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'dow', x.dw, 'h', x.h, 'days', dd.n,
        'orders_per_day', round(x.orders::numeric / greatest(dd.n, 1), 2),
        'cups_per_day',   round(x.drinks          / greatest(dd.n, 1), 2)
      ) order by x.dw, x.h), '[]'::jsonb)
      from hdow x join dd on dd.dw = x.dw),
    'bands', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'band', band, 'orders', orders, 'amount', amount) order by ord), '[]'::jsonb)
      from bands),
    'sizes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'n', n, 'orders', orders, 'amount', amount) order by n), '[]'::jsonb)
      from sizes),
    'mds_lift', (
      select jsonb_build_object(
        'with_n',      count(*) filter (where has_mds),
        'with_avg',    round(avg(total) filter (where has_mds)),
        'without_n',   count(*) filter (where not has_mds),
        'without_avg', round(avg(total) filter (where not has_mds)))
      from ob where n_items > 0)
  ) into v_out;

  return v_out;
end $$;

revoke all on function erp_order_analytics(int) from public, anon;
grant execute on function erp_order_analytics(int) to authenticated;
