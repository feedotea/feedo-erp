-- =====================================================================
-- 06_analytics.sql — 營運分析
--
-- 報表頁回答「這個月賺多少」；這支回答「生意在往哪裡走、該調整什麼」。
-- 跨月趨勢、星期幾的差別、什麼好賣、客人怎麼點、周邊賺多少，
-- 一次回傳，分析頁只打一次 RPC。
--
-- 建議本身在前端算（純規則，看得到怎麼推出來的），這裡只負責把
-- 「同一個維度的數字擺在一起」——建議要有說服力，靠的是可比較的分母。
--
-- 部署：在 05_pos_import.sql 之後跑。
-- =====================================================================

drop function if exists erp_analytics(int);

create or replace function erp_analytics(p_months int default 6)
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
  /* 每一筆銷售掛上分類。
     對應表的 category 是微碧自己分的（純茶類／奶蓋類／周邊／袋子…），
     比猜的準。還沒有分類的（少數舊資料）才退回關鍵字推斷。 */
  s as (
    select x.sales_on, x.order_no, x.qty, x.options, x.pos_name,
           case
             when m.category in ('周邊','袋子') then false
             when m.category is not null        then true
             else (x.options ~ '甜|冰' or x.pos_name ~ '茶|烏龍')
           end as is_drink
    from erp_pos_sales x
    left join erp_pos_item_map m on m.pos_name = x.pos_name
    where x.sales_on >= d_from
  ),
  /* 逐日的分類金額。只有匯過「營運總表」的日子才有 ——
     訂單列表拆不出單品的錢。has_cat 讓所有平均都只除有資料的天數，
     否則沒總表的日子會被當成「那天周邊賣 0」，把平均拉垮。 */
  cday as (
    select c.sales_on as d,
           sum(c.amount)                                          as cat_amount,
           sum(c.amount) filter (where mp.category = '周邊')       as mds_amount,
           sum(c.qty)    filter (where mp.category = '周邊')       as mds_qty,
           sum(c.qty * coalesce(i.cost, 0))
             filter (where mp.category = '周邊')                   as mds_cost,
           sum(c.qty) filter (where mp.category = '周邊'
                                and i.code is null)                as mds_unmapped
    from erp_pos_categories c
    left join erp_pos_item_map mp on mp.pos_name = c.pos_name
    left join erp_items i         on i.code = mp.item_code
    where c.sales_on >= d_from
    group by c.sales_on
  ),
  /* 逐日：營收來自 erp_revenue（POS 訂單總價，最可信），
     杯數／訂單數來自明細。星期分析和趨勢都建在這上面。 */
  daily as (
    select r.revenue_on as d, r.amount as revenue,
           coalesce(t.orders, 0)        as orders,
           coalesce(t.cups, 0)          as cups,
           coalesce(cd.cat_amount, 0)   as cat_amount,
           coalesce(cd.mds_amount, 0)   as mds_amount,
           coalesce(cd.mds_qty, 0)      as mds_qty,
           coalesce(cd.mds_cost, 0)     as mds_cost,
           coalesce(cd.mds_unmapped, 0) as mds_unmapped,
           (cd.d is not null)           as has_cat
    from erp_revenue r
    left join (
      select sales_on,
             count(distinct order_no) as orders,
             sum(qty) filter (where is_drink) as cups
      from s group by sales_on
    ) t   on t.sales_on = r.revenue_on
    left join cday cd on cd.d = r.revenue_on
    where r.revenue_on >= d_from
  ),
  months as (
    select to_char(d, 'YYYY-MM')          as m,
           count(*)::int                  as days,
           sum(revenue)                   as revenue,
           sum(orders)::int               as orders,
           sum(cups)::int                 as cups,
           count(*) filter (where has_cat)::int as cat_days,
           sum(cat_amount)                as cat_amount,
           sum(mds_amount)                as mds_amount,
           sum(mds_qty)                   as mds_qty,
           sum(mds_cost)                  as mds_cost,
           sum(mds_unmapped)              as mds_unmapped
    from daily group by 1
  ),
  dow as (
    select extract(dow from d)::int  as dow,
           count(*)::int             as days,
           round(avg(revenue))       as avg_revenue,
           round(avg(cups))          as avg_cups,
           round(avg(orders))        as avg_orders,
           sum(revenue)              as revenue,
           count(*) filter (where has_cat)::int as cat_days,
           round(avg(mds_amount) filter (where has_cat))      as avg_mds,
           round(avg(mds_qty)    filter (where has_cat), 1)   as avg_mds_qty,
           round(100 * sum(mds_amount) filter (where has_cat)
                 / nullif(sum(cat_amount) filter (where has_cat), 0), 1) as mds_pct
    from daily group by 1
  ),
  items as (
    select c.pos_name, max(mp.category) as category,
           sum(c.qty) as qty, sum(c.amount) as amount,
           sum(c.qty * coalesce(i.cost, 0)) as cost,
           bool_or(i.code is not null)      as mapped
    from erp_pos_categories c
    left join erp_pos_item_map mp on mp.pos_name = c.pos_name
    left join erp_items i         on i.code = mp.item_code
    where c.sales_on >= d_from
    group by c.pos_name
  ),
  /* 甜度／冰塊：決定備料和機器預設值。
     選項是逗號串，一杯可能有「3分甜,3分冰,封膜」三個 token。 */
  opt as (
    select case when tok ~ '甜|糖'   then 'sweet'
                when tok ~ '冰|溫|熱' then 'ice'
                else 'other' end as kind,
           tok, sum(s.qty) as qty
    from s, lateral unnest(string_to_array(s.options, ',')) as tok
    where s.is_drink and btrim(tok) <> ''
    group by 1, 2
  ),
  /* 最近 30 天沒什麼人點、但更早以前有在賣的品項 —— 該考慮下架的候選。
     只看飲料，周邊是季節性商品不適用。 */
  recent as (
    select c.pos_name,
           sum(c.qty) filter (where c.sales_on >  d_to - 30) as q30,
           sum(c.qty) filter (where c.sales_on <= d_to - 30) as q_prev
    from erp_pos_categories c
    left join erp_pos_item_map mp on mp.pos_name = c.pos_name
    where c.sales_on >= d_from
      and coalesce(mp.category, '') not in ('周邊', '袋子')
    group by c.pos_name
  )
  select jsonb_build_object(
    'from', d_from,
    'to',   d_to,
    'months', (
      select coalesce(jsonb_agg(to_jsonb(mo) order by mo.m), '[]'::jsonb) from months mo),
    'dow', (
      select coalesce(jsonb_agg(to_jsonb(dw) order by dw.dow), '[]'::jsonb) from dow dw),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', pos_name, 'category', category, 'qty', qty,
        'amount', amount, 'cost', cost, 'mapped', mapped
      ) order by amount desc), '[]'::jsonb)
      from (select * from items order by amount desc limit 30) t),
    'options', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'kind', kind, 'name', btrim(tok), 'qty', qty) order by qty desc), '[]'::jsonb)
      from opt where kind <> 'other'),
    'extras', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', btrim(tok), 'qty', qty) order by qty desc), '[]'::jsonb)
      from opt where kind = 'other'),
    'fading', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', pos_name, 'q30', coalesce(q30, 0), 'q_prev', coalesce(q_prev, 0)
      ) order by coalesce(q30, 0)), '[]'::jsonb)
      from recent
      where coalesce(q_prev, 0) >= 30
        and coalesce(q30, 0) < coalesce(q_prev, 0) * 0.25),
    'cat_total', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'category', category, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb)
      from (select coalesce(mp.category, '未分類') as category,
                   sum(c.qty) q, sum(c.amount) a
            from erp_pos_categories c
            left join erp_pos_item_map mp on mp.pos_name = c.pos_name
            where c.sales_on >= d_from group by 1) z)
  ) into v_out;

  return v_out;
end $$;

revoke all on function erp_analytics(int) from public, anon;
grant execute on function erp_analytics(int) to authenticated;
