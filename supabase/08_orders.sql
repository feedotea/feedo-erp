-- =====================================================================
-- 08_orders.sql — 逐筆訂單（時段分析 + 單筆訂單分析）
--
-- erp_pos_sales 是「一筆訂單裡的一個品項」，沒有時間也沒有整單金額。
-- 時段要看幾點忙、單筆要看一單買多少，兩個都得有訂單層的資料。
-- 訂單列表 CSV 本來就有「付款時間」和「總價」，只是以前沒存。
--
-- 刻意不改 erp_pos_import：那支已經在跑，裡面有包材自動扣料、
-- 重匯保護、分類回填，改簽名等於整個重寫一次，不值得。
-- 訂單改用獨立的 erp_pos_save_orders，匯入完再呼叫一次就好。
--
-- paid_at 存台北當地時間（timestamp，不帶時區）。報表全部是本地
-- 概念，帶時區反而要一路轉換，多一個出錯的地方。
--
-- 已經匯過的日子沒有這些資料 —— 重新匯同一份 CSV 就會補上。
-- 重複匯不會重複扣庫存（file_hash 擋掉），只會補訂單和分類。
--
-- 部署：在 07_ordering.sql 之後跑。可重複執行。
-- =====================================================================

create table if not exists erp_pos_orders (
  sales_on   date not null,
  order_no   text not null,
  paid_at    timestamp,                       -- 台北當地時間
  total      numeric(14,2) not null default 0,
  items      numeric(12,2) not null default 0,
  channel    text,                            -- 外帶／內用／外送
  updated_at timestamptz not null default now(),
  primary key (sales_on, order_no)
);

create index if not exists erp_pos_orders_date_idx on erp_pos_orders (sales_on);

alter table erp_pos_orders enable row level security;
alter table erp_pos_orders force  row level security;
revoke all on erp_pos_orders from anon, authenticated;

-- ---------------------------------------------------------------------
-- 存訂單。匯入完緊接著呼叫，同一張單重匯以最新的為準。
--   p_orders: [{"date":"2026-09-07","no":"240407",
--               "at":"2026-09-07 12:41:36","total":155,"items":2,"channel":"外帶"}]
-- ---------------------------------------------------------------------
create or replace function erp_pos_save_orders(p_orders jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  perform erp_require_manager();
  if p_orders is null or jsonb_array_length(p_orders) = 0 then
    return jsonb_build_object('ok', true, 'saved', 0);
  end if;

  insert into erp_pos_orders (sales_on, order_no, paid_at, total, items, channel, updated_at)
  select (o->>'date')::date, o->>'no',
         nullif(o->>'at','')::timestamp,
         coalesce((o->>'total')::numeric, 0),
         coalesce((o->>'items')::numeric, 0),
         nullif(o->>'channel',''), now()
  from jsonb_array_elements(p_orders) o
  where nullif(o->>'no','') is not null and nullif(o->>'date','') is not null
  on conflict (sales_on, order_no) do update set
    paid_at = excluded.paid_at, total = excluded.total,
    items = excluded.items, channel = excluded.channel, updated_at = now();

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'saved', n);
end $$;

revoke all on function erp_pos_save_orders(jsonb) from public, anon;
grant execute on function erp_pos_save_orders(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 時段 + 單筆訂單分析。分開一支，分析頁按到那一區才載。
--   p_months 跟 erp_analytics 同義（2 = 本月加上個月）
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
           bool_or(m.category = '周邊') as has_mds
    from erp_pos_sales s
    left join erp_pos_item_map m on m.pos_name = s.pos_name
    where s.sales_on >= d_from
    group by 1, 2
  ),
  ob as (
    select o.sales_on, o.order_no, o.total, o.paid_at,
           coalesce(li.n_items, o.items)  as n_items,
           coalesce(li.has_mds, false)    as has_mds
    from o left join li on li.sales_on = o.sales_on and li.order_no = o.order_no
  ),
  -- 有付款時間的營業日數。時段的「日均」要除這個，不是除有那小時的天數
  hd as (select count(distinct sales_on) as n from o where paid_at is not null),
  hrs as (
    select extract(hour from paid_at)::int as h,
           count(*)                  as orders,
           sum(total)                as amount,
           sum(n_items)              as items
    from ob where paid_at is not null
    group by 1
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
        'per_day',     round(orders::numeric / greatest((select n from hd), 1), 1),
        'amt_per_day', round(amount        / greatest((select n from hd), 1))
      ) order by h), '[]'::jsonb) from hrs),
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
