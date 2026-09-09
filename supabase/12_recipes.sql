-- =====================================================================
-- 12_recipes.sql — 飲料配方（BOM）+ 等候時間管線
--
-- 到目前為止只有周邊算得出毛利，飲料不行 —— 系統不知道一杯小葉紅
-- 鮮奶茶用掉多少鮮奶、多少糖。結果是開品、定價、砍品全部只能看
-- 銷量，看不到賺多少。賣最好的不一定最賺。
--
-- 茶葉不進配方：茶是「煮一桶扣一次」，已經在煮茶頁處理。
-- 紙杯封膜袋子也不進：那個走品項上的 pos_role，匯入時自動扣。
-- 配方要處理的是「跟著杯數走、又沒人會逐杯登記」的東西：
-- 鮮奶、鮮奶油、糖、配料。
--
-- 糖比較特別：同一杯飲料，3 分甜和無糖用的糖差 10 倍，而 POS 的
-- 選項欄剛好記著每一杯的甜度。所以糖的用量標成 scale_by_sweet，
-- 系統會按每一杯的實際甜度去乘 —— 這比填一個平均值準得多。
--
-- 部署：在 11_campaign.sql 之後跑。可重複執行。
-- =====================================================================

create table if not exists erp_recipes (
  pos_name       text not null,                 -- 微碧的飲料品名
  item_code      text not null references erp_items(code) on update cascade,
  qty            numeric(12,4) not null,        -- 一杯用多少（庫存單位）
  scale_by_sweet boolean not null default false,-- 糖：按每杯甜度比例縮放
  /* 只算成本、不扣庫存。
     茶葉是這個欄位存在的理由：一杯的毛利一定要含茶葉成本，
     但茶葉的庫存是煮茶頁按桶扣的，配方再扣一次就變兩倍。
     所以茶葉填「一杯用幾克」，只進成本不進扣料。 */
  deduct         boolean not null default true,
  updated_by     uuid references auth.users(id),
  updated_at     timestamptz not null default now(),
  primary key (pos_name, item_code)
);

alter table erp_recipes add column if not exists deduct boolean not null default true;

alter table erp_recipes enable row level security;
alter table erp_recipes force  row level security;
revoke all on erp_recipes from anon, authenticated;

-- 出餐時間。現在店裡是打烊才補，所以資料還不能用（確認到出餐
-- 中位數 80 分鐘，明顯不是真的）。欄位先留著，等出杯時真的按了
-- 那一下，等候時間就自己長出來。
alter table erp_pos_orders add column if not exists served_at timestamp;

-- ---------------------------------------------------------------------
-- 甜度 → 比例。POS 選項欄是逗號串，一杯可能有「3分甜,3分冰,封膜」。
-- 沒寫甜度的當全糖（1.0）—— 寧可高估用量，不要低估到缺料。
-- ---------------------------------------------------------------------
create or replace function erp_sweet_ratio(p_options text)
returns numeric
language sql immutable as $$
  select coalesce((
    select case
             when tok like '%無糖%' or tok like '%不加糖%' then 0
             when tok like '%全糖%' then 1
             when tok like '%半糖%' then 0.5
             when tok like '%少糖%' then 0.7
             when tok like '%微糖%' then 0.3
             when tok ~ '^\s*(\d+)\s*分(甜|糖)' then
               least(1, (regexp_replace(tok, '^\D*(\d+).*$', '\1'))::numeric / 10)
             else null
           end
    from unnest(string_to_array(coalesce(p_options,''), ',')) as tok
    where tok ~ '甜|糖'
    limit 1
  ), 1);
$$;

-- ---------------------------------------------------------------------
-- 配方編輯要的資料：飲料品名（按銷量排序）、目前配方、可選材料。
-- 茶葉和包材不列進材料選單 —— 它們有自己的扣料路徑，放進配方
-- 就會扣兩次。
-- ---------------------------------------------------------------------
create or replace function erp_recipes_config()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  perform erp_require_manager();
  select jsonb_build_object(
    'drinks', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', pos_name, 'category', category, 'qty', qty,
        'n_ing', (select count(*) from erp_recipes r where r.pos_name = t.pos_name)
      ) order by qty desc), '[]'::jsonb)
      from (
        select c.pos_name, max(mp.category) as category, sum(c.qty) as qty
        from erp_pos_categories c
        left join erp_pos_item_map mp on mp.pos_name = c.pos_name
        where coalesce(mp.category,'') not in ('周邊','袋子')
        group by c.pos_name
      ) t),
    'recipes', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'pos_name', pos_name, 'item_code', item_code, 'qty', qty,
        'scale_by_sweet', scale_by_sweet, 'deduct', deduct) order by pos_name), '[]'::jsonb)
      from erp_recipes),
    /* 材料選單。茶葉列進來但預設只算成本不扣料（is_tea 標出來讓前端擋）。
       包材和周邊不列：紙杯封膜袋子走 pos_role 自動扣，周邊是賣的商品，
       兩種都不該出現在飲料配方裡。 */
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'code', code, 'name', name, 'unit', unit, 'cat', cat,
        'cost', cost, 'is_tea', is_tea, 'pack_g', pack_g) order by cat, code), '[]'::jsonb)
      from erp_items
      where active and cat not in ('包材','周邊')),
    -- 每杯的包材成本（紙杯＋封膜）。這個不用人填，系統自己知道
    'pack_cost', (
      select coalesce(sum(cost), 0) from erp_items
      where active and pos_role in ('cup','film'))
  ) into v_out;
  return v_out;
end $$;

-- 一次存一支飲料的整份配方（先清再寫，才刪得掉材料）
create or replace function erp_save_recipe(p_pos_name text, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := erp_require_manager(); n int := 0;
begin
  if coalesce(p_pos_name,'') = '' then
    raise exception '沒有指定飲料' using errcode = '22023';
  end if;
  delete from erp_recipes where pos_name = p_pos_name;
  if p_rows is not null and jsonb_array_length(p_rows) > 0 then
    insert into erp_recipes (pos_name, item_code, qty, scale_by_sweet, deduct, updated_by, updated_at)
    select p_pos_name, r->>'item_code',
           coalesce((r->>'qty')::numeric, 0),
           coalesce((r->>'scale_by_sweet')::boolean, false),
           -- 茶葉一律只算成本。前端擋一次，後端再擋一次，不靠前端守規矩
           coalesce((r->>'deduct')::boolean, true)
             and not exists (select 1 from erp_items i
                             where i.code = r->>'item_code' and i.is_tea),
           uid, now()
    from jsonb_array_elements(p_rows) r
    where coalesce(r->>'item_code','') <> '' and coalesce((r->>'qty')::numeric,0) > 0;
    get diagnostics n = row_count;
  end if;
  return jsonb_build_object('ok', true, 'pos_name', p_pos_name, 'rows', n);
end $$;

-- ---------------------------------------------------------------------
-- 配方扣料。跟包材一樣走「整天重算」：先刪掉那幾天的配方扣料，
-- 再依當天實際賣出的杯數重新算一次。重匯、改配方都不會疊加。
-- ---------------------------------------------------------------------
create or replace function erp_recipe_deduct(p_dates date[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := erp_require_manager(); n int := 0;
begin
  if p_dates is null or array_length(p_dates,1) is null then
    return jsonb_build_object('ok', true, 'moves', 0);
  end if;

  delete from erp_stock_moves
   where kind = 'use' and note = '配方自動扣料' and occurred_on = any(p_dates);

  insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, note, created_by)
  select gen_random_uuid(), u.item_code, 'use', -u.q, u.d, '配方自動扣料', uid
  from (
    select s.sales_on as d, r.item_code,
           sum(s.qty * r.qty *
               case when r.scale_by_sweet then erp_sweet_ratio(s.options) else 1 end) as q
    from erp_pos_sales s
    join erp_recipes r on r.pos_name = s.pos_name and r.deduct
    where s.sales_on = any(p_dates)
      and s.options not like '%贈品%'
    group by 1, 2
  ) u
  where u.q > 0;

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'moves', n, 'days', array_length(p_dates,1));
end $$;

revoke all on function erp_sweet_ratio(text)          from public, anon;
revoke all on function erp_recipes_config()            from public, anon;
revoke all on function erp_save_recipe(text, jsonb)    from public, anon;
revoke all on function erp_recipe_deduct(date[])       from public, anon;
grant execute on function erp_sweet_ratio(text)        to authenticated;
grant execute on function erp_recipes_config()          to authenticated;
grant execute on function erp_save_recipe(text, jsonb)  to authenticated;
grant execute on function erp_recipe_deduct(date[])     to authenticated;
