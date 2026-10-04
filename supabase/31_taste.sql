-- =====================================================================
-- 31_taste.sql — 試喝整杯記損耗 ＋ 損耗算進物料成本
--
-- 老闆：店裡會給客人試喝奶茶，通常是整杯 500cc。
-- 一杯奶茶材料 17～27 元，一天幾杯一個月就是幾千元，要記。
--
-- 三件事：
-- 1. erp_recipe_names()：店員也讀得到的「有配方的飲料名單」。
--    記損耗要讓店員選「試喝了哪一支」，但 erp_recipes_config 限店長而且回成本。
--    這支只回名字。
-- 2. erp_cap_recipe 多回 scale_by_sweet：試喝整杯的糖要按店裡預設甜度縮，
--    不然每杯多扣 15cc 糖。回傳格式向下相容（多一個 key）。
-- 3. 損耗算進物料成本：erp_month_report / erp_month_series 的 cogs 原本只算
--    brew/use。煮壞、過期、試喝這些 waste 都是真的花掉的料，之前在損益表上
--    看不到 —— 記得再勤也是白記。改成 brew/use/waste 都算。
--    ⚠ 改完之後各月毛利率會往下修一點，那才是真的數字。
--    盤點（stocktake）仍然不算，它是校正不是耗用。
--
-- 函式裡刻意不寫中文字串（29 號的「廠商貨款」用 chr() 拼），
-- 貼的時候照樣用 LC_ALL=en_US.UTF-8 pbcopy。可重複執行。
-- =====================================================================

-- 1. 有配方的飲料名單（只回名字，店長店員都拿得到）
create or replace function erp_recipe_names()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform erp_require_staff();
  return coalesce((
    select jsonb_agg(pos_name order by pos_name)
    from (select distinct pos_name from erp_recipes) t
  ), '[]'::jsonb);
end $$;
revoke all    on function erp_recipe_names() from public, anon;
grant execute on function erp_recipe_names() to authenticated;

-- 2. 配方多回 scale_by_sweet（不回成本，和 24 號同一條線）
create or replace function erp_cap_recipe(p_name text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform erp_require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'item_code',      r.item_code,
             'qty',            r.qty,
             'deduct',         r.deduct,
             'scale_by_sweet', r.scale_by_sweet
           ) order by r.qty desc)
    from erp_recipes r
    where r.pos_name = p_name
  ), '[]'::jsonb);
end $$;
revoke all    on function erp_cap_recipe(text) from public, anon;
grant execute on function erp_cap_recipe(text) to authenticated;

-- 3. 損耗算進物料成本 —— 下面兩支是原本的定義，只改 kind in (...) 那一行
create or replace function erp_month_report(p_month text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m_start date;
  m_end   date;
begin
  perform erp_require_manager();
  m_start := to_date(p_month || '-01', 'YYYY-MM-DD');
  m_end   := (m_start + interval '1 month')::date;

  return jsonb_build_object(
    'month', p_month,
    'revenue',  (select coalesce(sum(amount),0) from erp_revenue
                 where revenue_on >= m_start and revenue_on < m_end),
    'expense',  (select coalesce(sum(amount),0) from erp_expenses
                 where spent_on >= m_start and spent_on < m_end),
    'by_cat',   (select coalesce(jsonb_object_agg(cat, s), '{}'::jsonb) from (
                   select cat, sum(amount) s from erp_expenses
                   where spent_on >= m_start and spent_on < m_end group by cat) t),
    'by_payee', (select coalesce(jsonb_object_agg(payee, s), '{}'::jsonb) from (
                   select payee, sum(amount) s from erp_expenses
                   where spent_on >= m_start and spent_on < m_end group by payee) t),
    'days',     (select coalesce(jsonb_agg(jsonb_build_object('date', revenue_on, 'amt', amount)
                                           order by revenue_on), '[]'::jsonb)
                 from erp_revenue where revenue_on >= m_start and revenue_on < m_end),
    -- 當月耗用的原料成本（用目前單價估）
    'cogs',     (select coalesce(sum(-m.qty_delta * i.cost), 0)
                 from erp_stock_moves m join erp_items i on i.code = m.item_code
                 where m.kind in ('brew','use','waste') and m.qty_delta < 0
                   and m.occurred_on >= m_start and m.occurred_on < m_end),

    /* POS 營運數字。
       「哪些算飲料」目前用推斷：有甜度或冰塊選項、或品名含茶/烏龍。
       這樣杯套、T-Shirt、帽子、貼紙、紙袋、兩杯袋不會被算進杯數，
       而沒有甜冰選項的維也納奶茶還是算得到。
       等 erp_pos_item_map 對應完就改用正式分類。 */
    'pos',      (select jsonb_build_object(
                   'orders', count(distinct order_no),
                   'cups',   coalesce(sum(qty) filter (where is_drink), 0),
                   'others', coalesce(sum(qty) filter (where not is_drink), 0),
                   'eco',    coalesce(sum(qty) filter (where options like '%環保杯%'), 0),
                   'film',   coalesce(sum(qty) filter (where options like '%封膜%'), 0))
                 from (select order_no, qty, options,
                              (options ~ '甜|冰' or pos_name ~ '茶|烏龍') as is_drink
                       from erp_pos_sales
                       where sales_on >= m_start and sales_on < m_end) x),

    /* 營收組成：微碧自己分的類別（奶蓋類／純茶類／鮮奶茶類／袋子／周邊…）。
       這是唯一能把周邊商品的錢跟飲料分開的來源 ——
       訂單列表只有整張單的總價，拆不出單品營收。 */
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object(
                        'category', category, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb)
                    from (select category, sum(qty) as q, sum(amount) as a
                          from erp_pos_categories
                          where sales_on >= m_start and sales_on < m_end
                          group by category) c),

    'top',      (select coalesce(jsonb_agg(jsonb_build_object('name', pos_name, 'qty', q)
                                           order by q desc), '[]'::jsonb)
                 from (select pos_name, sum(qty) as q from erp_pos_sales
                       where sales_on >= m_start and sales_on < m_end
                         and (options ~ '甜|冰' or pos_name ~ '茶|烏龍')
                       group by pos_name order by q desc limit 10) t)
  );
end $$;

create or replace function erp_month_series(p_months int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  n int := greatest(1, least(coalesce(p_months, 12), 36));
  m0 date := (date_trunc('month', erp_today()) - make_interval(months => n - 1))::date;
begin
  perform erp_require_manager();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'month',   to_char(g.m, 'YYYY-MM'),
             'revenue', coalesce(r.amt, 0),
             'days',    coalesce(r.days, 0),
             'cogs',    coalesce(c.amt, 0),
             'opex',    coalesce(e.amt, 0))
           order by g.m desc)
      from generate_series(m0, date_trunc('month', erp_today())::date, interval '1 month') g(m)
      left join lateral (
        select sum(amount) amt, count(*) days from erp_revenue
         where revenue_on >= g.m and revenue_on < (g.m + interval '1 month')
      ) r on true
      left join lateral (
        select sum(-sm.qty_delta * i.cost) amt
          from erp_stock_moves sm join erp_items i on i.code = sm.item_code
         where sm.kind in ('brew','use','waste') and sm.qty_delta < 0
           and sm.occurred_on >= g.m and sm.occurred_on < (g.m + interval '1 month')
      ) c on true
      left join lateral (
        select sum(amount) amt from erp_expenses
         where spent_on >= g.m and spent_on < (g.m + interval '1 month')
           -- 廠商貨款是現金流，不是成本
           and cat <> chr(24288)||chr(21830)||chr(36008)||chr(27454)
      ) e on true
  ), '[]'::jsonb);
end $$;

revoke all    on function erp_month_series(int) from public, anon;
grant execute on function erp_month_series(int) to authenticated;

-- ---------------------------------------------------------------------
-- 驗證（純 ASCII）：五列都要 true（最後一列檢查 erp_month_report 裡的中文沒被貼壞：「環保杯」）
-- select 'names',   prosrc like '%erp_require_staff%' from pg_proc where proname='erp_recipe_names'
-- union all select 'cap_sweet', prosrc like '%scale_by_sweet%' from pg_proc where proname='erp_cap_recipe'
-- union all select 'report_waste', prosrc like '%''waste'')%' from pg_proc where proname='erp_month_report'
-- union all select 'series_waste', prosrc like '%''waste'')%' from pg_proc where proname='erp_month_series'
-- union all select 'report_zh', prosrc like '%'||chr(29872)||chr(20445)||chr(26479)||'%' from pg_proc where proname='erp_month_report';
-- ---------------------------------------------------------------------
