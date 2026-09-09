-- =====================================================================
-- FEEDO ERP · RPC 介面
-- 前端只碰這裡的 function，不直接 select/insert 任何表。
--
-- 慣例：
--   · 所有寫入的第一件事是 erp_require_staff()，沒登入就 raise。
--   · 需要擋重送的寫入都吃前端產生的 uuid，on conflict do nothing。
--     → 送出後斷線，前端用「同一個 id」重試即可，不會變兩筆。
--   · 一律回傳 jsonb，前端拿得到確認，不再是射後不理。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 權限分界
--   staff   ：每天的現場操作 —— 煮茶、進貨、用量、報廢、叫貨、看庫存
--   manager ：錢與設定 —— 開銷、報表、月結、盤點、品項主檔、刪除任何紀錄
--
-- 前端會把店長的按鈕藏起來，但那只是 UX。
-- 真正的線畫在這裡：藏起來的按鈕，店員開 devtools 一樣叫得到 RPC。
-- ---------------------------------------------------------------------
create or replace function erp_require_manager() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := erp_require_staff();
begin
  if not erp_is_manager() then
    raise exception '這個功能限店長使用' using errcode = '42501';
  end if;
  return uid;
end $$;

-- ---------------------------------------------------------------------
-- 開 App 一次撈完（取代原本 GAS 的 GET 全表）
-- ---------------------------------------------------------------------
create or replace function erp_bootstrap(p_months int default 3)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from date;
  v_mgr  boolean;
begin
  perform erp_require_staff();
  v_mgr  := erp_is_manager();
  v_from := (date_trunc('month', erp_today()) - ((p_months - 1) * interval '1 month'))::date;

  -- 店員不會拿到 expenses / revenue。資料根本不送出去，
  -- 而不是送出去再靠前端不顯示。
  return jsonb_build_object(
    'today',    erp_today(),
    'me',       (select jsonb_build_object('name', name, 'role', role)
                 from erp_staff where user_id = auth.uid()),
    -- 成本只給店長。畫面上店員本來就看不到，但不送出去才是真的看不到 ——
    -- 否則開 devtools 讀 items[i].cost 就拿得到每個品項的進貨價。
    'items',    (select coalesce(jsonb_agg(
                   case when v_mgr then to_jsonb(v)
                        else jsonb_set(to_jsonb(v), '{cost}', '0'::jsonb) end
                   order by v.cat, v.sort_order, v.code), '[]'::jsonb)
                 from erp_v_items v),
    'orders',   (select coalesce(jsonb_agg(to_jsonb(o) order by o.ordered_on desc), '[]'::jsonb)
                 from erp_orders o where o.status = 'pending'),
    'expenses', case when v_mgr then
                 (select coalesce(jsonb_agg(to_jsonb(e) order by e.spent_on desc, e.created_at desc), '[]'::jsonb)
                  from erp_expenses e where e.spent_on >= v_from)
                 else '[]'::jsonb end,
    'revenue',  case when v_mgr then
                 (select coalesce(jsonb_agg(to_jsonb(r) order by r.revenue_on desc), '[]'::jsonb)
                  from erp_revenue r where r.revenue_on >= v_from)
                 else '[]'::jsonb end,
    'cats',     (select coalesce(jsonb_agg(distinct cat), '[]'::jsonb) from erp_items where active),
    -- 今天已經登記的煮茶量（公克）。待辦卡片用它判斷「今天還沒記煮茶」。
    'brewed_today', (select coalesce(sum(-qty_delta), 0) from erp_stock_moves
                     where kind = 'brew' and occurred_on = erp_today())
  );
end $$;

-- ---------------------------------------------------------------------
-- 煮茶登記（可補登過去日期）＋ 當日營收
-- p_rows: [{"id":"uuid","code":"TEA-01","buckets":2.5}, ...]
-- ---------------------------------------------------------------------
create or replace function erp_log_brew(
  p_rows    jsonb,
  p_date    date    default null,
  p_revenue numeric default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := erp_require_staff();
  d    date := coalesce(p_date, erp_today());
  r    jsonb;
  n    int  := 0;
begin
  if d > erp_today() then
    raise exception '不能登記未來日期' using errcode = '22007';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, buckets, created_by)
    select (r->>'id')::uuid,
           i.code,
           'brew',
           -((r->>'buckets')::numeric * i.pack_g),
           d,
           (r->>'buckets')::numeric,
           uid
    from erp_items i
    where i.code = r->>'code' and (r->>'buckets')::numeric > 0
    on conflict (id) do nothing;
    n := n + 1;
  end loop;

  if p_revenue is not null and p_revenue >= 0 then
    insert into erp_revenue (revenue_on, amount, updated_by, updated_at)
    values (d, p_revenue, uid, now())
    on conflict (revenue_on)
      do update set amount = excluded.amount,
                    updated_by = excluded.updated_by,
                    updated_at = now();
  end if;

  return jsonb_build_object('ok', true, 'date', d, 'rows', n,
                            'items', (select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb)
                                      from erp_v_items v where v.is_tea));
end $$;

-- ---------------------------------------------------------------------
-- 單筆物料異動：進貨 / 用量 / 報廢
-- ---------------------------------------------------------------------
-- 多了 p_unit_cost 這個參數，簽章就變了。
-- create or replace 遇到不同簽章是「新增一個多載」而不是取代，
-- 舊的那個會留著而且完全忽略單價，所以一定要先砍掉。
drop function if exists erp_log_move(uuid, text, text, numeric, text, date);
drop function if exists erp_log_move(uuid, text, text, numeric, text, date, numeric);

create or replace function erp_log_move(
  p_id   uuid,
  p_code text,
  p_kind text,          -- receive | use | waste
  p_qty  numeric,       -- 一律填正數，方向由 p_kind 決定
  p_note text default '',
  p_date date default null,
  p_unit_cost numeric default null,  -- 進貨才有意義；月結拿不到價格就留 null
  -- 只有「叫貨頁按到貨」才該把等貨中的單結掉。
  -- 臨時去別家買一斤應急，不該讓松霖那張單變成已到貨。
  p_close_order boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid   uuid := erp_require_staff();
  d     date := coalesce(p_date, erp_today());
  delta numeric;
  old_bal  numeric;
  old_cost numeric;
  ins   int;
begin
  if p_kind not in ('receive','use','waste') then
    raise exception '不支援的異動類型：%', p_kind using errcode = '22023';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception '數量必須大於 0' using errcode = '22023';
  end if;

  delta := case when p_kind = 'receive' then p_qty else -p_qty end;

  insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, note, unit_cost, created_by)
  values (p_id, p_code, p_kind, delta, d, coalesce(p_note,''), p_unit_cost, uid)
  on conflict (id) do nothing;
  get diagnostics ins = row_count;   -- 0 = 這筆已經寫過了（離線佇列重送）

  if p_kind = 'receive' then
    -- 這批是不是那張單的貨，只有前端知道，所以用旗標而不是自己猜
    if p_close_order then
      update erp_orders
         set status = 'received', received_on = d
       where item_code = p_code and status = 'pending';
    end if;

    -- 有報價才動成本，用移動平均：(舊庫存×舊成本 + 進貨量×進貨單價) / 總量
    -- 直接覆蓋成最新價會讓舊庫存的成本憑空跳動，毛利就不準了。
    -- ins = 0 代表這是重送，庫存沒有再增加，成本也不能再平均一次
    if ins = 1 and p_unit_cost is not null and p_unit_cost >= 0 then
      select coalesce(b.bal, 0), i.cost into old_bal, old_cost
        from erp_items i left join erp_v_balance b on b.code = i.code
       where i.code = p_code;
      -- old_bal 已含這筆進貨（view 是即時加總），所以要扣回去
      old_bal := greatest(old_bal - p_qty, 0);
      update erp_items
         set cost = case when old_bal + p_qty > 0
                         then round((old_bal * old_cost + p_qty * p_unit_cost) / (old_bal + p_qty), 4)
                         else p_unit_cost end,
             updated_at = now()
       where code = p_code;
    end if;
  end if;

  return jsonb_build_object('ok', true,
    'item', (select to_jsonb(v) from erp_v_items v where v.code = p_code));
end $$;

-- ---------------------------------------------------------------------
-- 盤點：寫成一筆「調整」，不覆蓋歷史
-- p_rows: [{"id":"uuid","code":"PKG-01","counted":1850}, ...]
-- ---------------------------------------------------------------------
create or replace function erp_stocktake(p_rows jsonb, p_date date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  -- 盤點開放給店員：實際去數貨的是工讀生，鎖成店長等於沒人能盤。
  -- 控制改成「事後看得到」而不是「事前擋住」——每筆調整都記
  -- created_by 和「系統 X → 實際 Y」的差額，店長查得到是誰在什麼
  -- 時候調了多少。小店的規模，偵測比審批實際。
  uid   uuid := erp_require_staff();
  d     date := coalesce(p_date, erp_today());
  r     jsonb;
  cur   numeric;
  diff  numeric;
  fixed int := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    -- 鎖住品項，避免盤點算 diff 的當下有人在別台送煮茶
    perform 1 from erp_items where code = r->>'code' for update;

    select bal into cur from erp_v_balance where code = r->>'code';
    diff := (r->>'counted')::numeric - coalesce(cur, 0);

    if diff <> 0 then
      insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, note, created_by)
      values ((r->>'id')::uuid, r->>'code', 'stocktake', diff, d,
              format('盤點 系統 %s → 實際 %s', cur, r->>'counted'), uid)
      on conflict (id) do nothing;
      fixed := fixed + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'adjusted', fixed,
    'items', (select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) from erp_v_items v));
end $$;

-- ---------------------------------------------------------------------
-- 叫貨
-- p_rows: [{"id":"uuid","code":"TEA-01","qty":3,"unit":"斤","supplier":"松霖"}, ...]
-- ---------------------------------------------------------------------
create or replace function erp_place_orders(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := erp_require_staff();
  r    jsonb;
  cnt  int := 0;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    -- 同品項已有等貨中的單就改數量，不再開第二張
    -- （erp_orders_one_pending_idx 是 partial unique，on conflict (id) 擋不到它）
    update erp_orders
       set qty = (r->>'qty')::numeric,
           unit = r->>'unit',
           ordered_on = erp_today(),
           created_by = uid
     where item_code = r->>'code' and status = 'pending';

    if not found then
      insert into erp_orders (id, item_code, supplier, qty, unit, ordered_on, created_by)
      values ((r->>'id')::uuid, r->>'code', r->>'supplier',
              (r->>'qty')::numeric, r->>'unit', erp_today(), uid)
      on conflict (id) do nothing;
    end if;
    cnt := cnt + 1;
  end loop;

  return jsonb_build_object('ok', true, 'count', cnt,
    'orders', (select coalesce(jsonb_agg(to_jsonb(o)), '[]'::jsonb)
               from erp_orders o where o.status = 'pending'));
end $$;

create or replace function erp_cancel_order(p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform erp_require_staff();
  update erp_orders set status = 'cancelled'
   where item_code = p_code and status = 'pending';
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 品項維護（僅 manager 以上）
-- ---------------------------------------------------------------------
create or replace function erp_save_item(p_item jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform erp_require_manager();

  insert into erp_suppliers (name)
  select p_item->>'supplier'
  where coalesce(p_item->>'supplier','') not in ('', '—')
  on conflict (name) do nothing;

  insert into erp_items (code, name, cat, unit, safe_qty, cost, supplier,
                         is_tea, pack_g, avg_per_day_manual, note, sort_order, updated_at)
  values (p_item->>'code',
          p_item->>'name',
          coalesce(p_item->>'cat','其他'),
          coalesce(p_item->>'unit','個'),
          coalesce((p_item->>'safe_qty')::numeric, 0),
          coalesce((p_item->>'cost')::numeric, 0),
          nullif(nullif(p_item->>'supplier',''),'—'),
          coalesce((p_item->>'is_tea')::boolean, false),
          coalesce((p_item->>'pack_g')::numeric, 100),
          coalesce((p_item->>'avg_per_day_manual')::numeric, 0),
          coalesce(p_item->>'note',''),
          coalesce((p_item->>'sort_order')::int, 0),
          now())
  on conflict (code) do update set
    name = excluded.name, cat = excluded.cat, unit = excluded.unit,
    safe_qty = excluded.safe_qty, cost = excluded.cost, supplier = excluded.supplier,
    is_tea = excluded.is_tea, pack_g = excluded.pack_g,
    avg_per_day_manual = excluded.avg_per_day_manual,
    note = excluded.note, sort_order = excluded.sort_order,
    active = true, updated_at = now();

  return jsonb_build_object('ok', true,
    'item', (select to_jsonb(v) from erp_v_items v where v.code = p_item->>'code'));
end $$;

-- 有異動紀錄的品項只下架不刪除，帳才不會出現斷點
create or replace function erp_delete_item(p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare has_history boolean;
begin
  perform erp_require_manager();

  select exists (select 1 from erp_stock_moves where item_code = p_code) into has_history;

  if has_history then
    update erp_items set active = false, updated_at = now() where code = p_code;
    return jsonb_build_object('ok', true, 'mode', 'archived');
  else
    delete from erp_items where code = p_code;
    return jsonb_build_object('ok', true, 'mode', 'deleted');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 帳務
-- ---------------------------------------------------------------------
create or replace function erp_add_expense(
  p_id     uuid,
  p_cat    text,
  p_amount numeric,
  p_payee  text default '—',
  p_method text default '轉帳',
  p_note   text default '',
  p_date   date default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := erp_require_manager();
begin
  insert into erp_expenses (id, spent_on, cat, amount, payee, method, note, created_by)
  values (p_id, coalesce(p_date, erp_today()), p_cat, p_amount,
          coalesce(nullif(p_payee,''),'—'), p_method, coalesce(p_note,''), uid)
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;

-- 用 id 刪，不再靠 (日期,類別,金額,對象) 比對
create or replace function erp_delete_expense(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform erp_require_manager();
  delete from erp_expenses where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function erp_set_revenue(p_date date, p_amount numeric)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := erp_require_manager();
begin
  insert into erp_revenue (revenue_on, amount, updated_by, updated_at)
  values (p_date, p_amount, uid, now())
  on conflict (revenue_on) do update set
    amount = excluded.amount, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function erp_delete_revenue(p_date date)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform erp_require_manager();
  delete from erp_revenue where revenue_on = p_date;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 月報表：營收、支出分類、毛估損益
-- ---------------------------------------------------------------------
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
                 where m.kind in ('brew','use') and m.qty_delta < 0
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

    'top',      (select coalesce(jsonb_agg(jsonb_build_object('name', pos_name, 'qty', q)
                                           order by q desc), '[]'::jsonb)
                 from (select pos_name, sum(qty) as q from erp_pos_sales
                       where sales_on >= m_start and sales_on < m_end
                         and (options ~ '甜|冰' or pos_name ~ '茶|烏龍')
                       group by pos_name order by q desc limit 10) t)
  );
end $$;
