-- =====================================================================
-- 11_campaign.sql — 活動期間對比
--
-- 「這個活動有沒有效」很難答，因為活動期間店裡什麼都在變：季節、
-- 天氣、開學、隔壁開店。單看活動期間的數字漲跌，等於把所有原因
-- 都算在活動頭上。
--
-- 這裡做的是最基本但誠實的一種比較：拿活動期間，對比緊接在前面
-- 等長的一段日子，而且只比同一個星期幾 —— 週六對週六、週三對週三。
-- 這樣至少排除掉「活動剛好排在週末多的那幾天」這種假象。
--
-- 排不掉的是季節。FEEDO 在觀光區，八月中觀光季一結束，什麼活動
-- 都會看起來沒效。所以回傳一定要帶上基準期的日期，讓看的人自己
-- 判斷那段時間本來就在漲還是在跌 —— 只給一個百分比是不負責任的。
--
-- 部署：在 10_orders_fix.sql 之後跑。可重複執行。
-- =====================================================================

drop function if exists erp_campaign_report(date, date, text);

create or replace function erp_campaign_report(
  p_from date,
  p_to   date,
  p_item text default null      -- 想追蹤的主打商品關鍵字，例如「維也納」
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  n_days int;
  b_from date;
  b_to   date;
  v_out  jsonb;
begin
  perform erp_require_manager();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception '活動日期不對' using errcode = '22023';
  end if;

  n_days := (p_to - p_from) + 1;
  b_to   := p_from - 1;
  b_from := b_to - (n_days - 1);

  with
  li as (
    select s.sales_on, s.order_no,
           sum(s.qty) filter (where coalesce(m.category,'') not in ('周邊','袋子')) as drinks,
           sum(s.qty) filter (where m.category = '周邊'
                                and s.options not like '%贈品%')                    as mds,
           sum(s.qty) filter (where s.options like '%贈品%')                        as gifts,
           sum(s.qty) filter (where p_item is not null and s.pos_name like '%'||p_item||'%'
                                and s.options not like '%贈品%')                    as target
    from erp_pos_sales s
    left join erp_pos_item_map m on m.pos_name = s.pos_name
    where s.sales_on between b_from and p_to
    group by 1, 2
  ),
  d as (
    select r.revenue_on as d,
           case when r.revenue_on >= p_from then 'cur' else 'base' end as seg,
           extract(dow from r.revenue_on)::int as dow,
           r.amount as revenue,
           coalesce(t.orders, 0) as orders,
           coalesce(t.drinks, 0) as cups,
           coalesce(t.mds, 0)    as mds,
           coalesce(t.gifts, 0)  as gifts,
           coalesce(t.target, 0) as target
    from erp_revenue r
    left join (
      select sales_on, count(*) as orders,
             sum(coalesce(drinks,0)) as drinks, sum(coalesce(mds,0)) as mds,
             sum(coalesce(gifts,0))  as gifts,  sum(coalesce(target,0)) as target
      from li group by sales_on
    ) t on t.sales_on = r.revenue_on
    where r.revenue_on between b_from and p_to
  ),
  agg as (
    select seg, count(*)::int as days,
           sum(revenue) as revenue, sum(orders)::int as orders,
           sum(cups)::int as cups, sum(mds)::int as mds,
           sum(gifts)::int as gifts, sum(target)::int as target
    from d group by seg
  ),
  /* 同星期幾對同星期幾。活動期和基準期的星期組成不一定一樣
     （19 天不是 7 的倍數），所以一律用日均比，不用總量。 */
  bydow as (
    select dow,
           count(*) filter (where seg='cur')::int   as cur_days,
           count(*) filter (where seg='base')::int  as base_days,
           round(avg(cups)    filter (where seg='cur'))   as cur_cups,
           round(avg(cups)    filter (where seg='base'))  as base_cups,
           round(avg(revenue) filter (where seg='cur'))   as cur_rev,
           round(avg(revenue) filter (where seg='base'))  as base_rev
    from d group by dow
  ),
  /* 哪些品項的銷量變化最大。活動主打什麼、犧牲了什麼，這裡看得到。 */
  mov as (
    select s.pos_name,
           sum(s.qty) filter (where s.sales_on >= p_from)                    as cur_qty,
           sum(s.qty) filter (where s.sales_on <  p_from)                    as base_qty
    from erp_pos_sales s
    where s.sales_on between b_from and p_to and s.options not like '%贈品%'
    group by 1
  ),
  movd as (
    select pos_name,
           coalesce(cur_qty,0)::numeric  / greatest((select days from agg where seg='cur'),1)  as cur_pd,
           coalesce(base_qty,0)::numeric / greatest((select days from agg where seg='base'),1) as base_pd
    from mov
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', n_days,
    'base_from', b_from, 'base_to', b_to,
    'cur',  (select to_jsonb(a) from agg a where seg='cur'),
    'base', (select to_jsonb(a) from agg a where seg='base'),
    'item', p_item,
    'dow', (
      select coalesce(jsonb_agg(to_jsonb(b) order by b.dow), '[]'::jsonb)
      from bydow b where cur_days > 0 and base_days > 0),
    'up', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', pos_name, 'cur', round(cur_pd,1), 'base', round(base_pd,1),
        'diff', round(cur_pd - base_pd, 1)) order by (cur_pd - base_pd) desc), '[]'::jsonb)
      from (select * from movd where cur_pd - base_pd > 0.5 order by cur_pd - base_pd desc limit 8) x),
    'down', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', pos_name, 'cur', round(cur_pd,1), 'base', round(base_pd,1),
        'diff', round(cur_pd - base_pd, 1)) order by (cur_pd - base_pd)), '[]'::jsonb)
      from (select * from movd where base_pd - cur_pd > 0.5 order by cur_pd - base_pd limit 8) x)
  ) into v_out;

  return v_out;
end $$;

revoke all on function erp_campaign_report(date, date, text) from public, anon;
grant execute on function erp_campaign_report(date, date, text) to authenticated;
