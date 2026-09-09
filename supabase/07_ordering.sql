-- =====================================================================
-- 07_ordering.sql — 叫貨改用「還能撐幾天」
--
-- 原本的判斷是 bal <= safe_qty：庫存掉到安全量才叫。問題是叫了不會
-- 馬上到 —— 茶葉要 3 天、封膜更久。等掉到安全量才下單，那段等貨的
-- 日子就是在吃安全庫存，遇到週末大量就直接見底。
--
-- 改成：剩餘天數 = 庫存 ÷ 日用量，剩餘天數 <= 到貨天數 + 緩衝 就該叫。
-- 叫多少也不再用 safe*1.5 這個跟用量無關的數字，改成「補到能撐
-- 到貨天數 + 補貨週期」，而且要扣掉已經在路上的量。
--
-- 部署：在 01〜06 之後跑。可重複執行。
-- =====================================================================

alter table erp_items add column if not exists lead_days  int not null default 3;
alter table erp_items add column if not exists cover_days int not null default 14;

comment on column erp_items.lead_days  is '下單到到貨要幾天';
comment on column erp_items.cover_days is '叫一次要夠撐幾天（不含到貨天數）';

-- 茶葉月結、量大，可以叫多一點；包材佔空間，週期短一些
update erp_items set cover_days = 21 where is_tea and cover_days = 14;

-- ---------------------------------------------------------------------
-- 在途量：已下單還沒到的，換算回庫存單位。
-- 訂單存的是採購單位（茶葉是「斤」），跟 items.unit（g）不同，
-- 缺口要扣在途量之前得先換算，否則會重複下單。
-- ---------------------------------------------------------------------
create or replace view erp_v_on_order as
select o.item_code as code,
       sum(case
             when i.order_unit is not null and o.unit = i.order_unit
                  and coalesce(i.order_pack, 0) > 0 then o.qty * i.order_pack
             when o.unit = '斤' and i.unit = 'g'     then o.qty * 600
             else o.qty
           end) as on_order_qty
from erp_orders o
join erp_items i on i.code = o.item_code
where o.status = 'pending'
group by o.item_code;

-- erp_v_items 要加欄位，CREATE OR REPLACE VIEW 不能插在中間，先 drop
drop view if exists erp_v_items;
create view erp_v_items as
select
  i.code, i.name, i.cat, i.unit, i.safe_qty, i.cost, i.supplier,
  i.is_tea, i.pack_g, i.note, i.sort_order, i.avg_per_day_manual,
  i.pos_role, i.order_unit, i.order_pack,
  i.lead_days, i.cover_days,
  b.bal,
  -- 累積 14 天以上實際資料才敢用真實數據，否則沿用手填值
  case when u.days_with_data >= 14 and u.avg_actual > 0
       then round(u.avg_actual, 3)
       else i.avg_per_day_manual
  end as avg_per_day,
  (u.days_with_data >= 14 and u.avg_actual > 0) as avg_is_actual,
  exists (select 1 from erp_orders o
          where o.item_code = i.code and o.status = 'pending') as on_order,
  coalesce(oo.on_order_qty, 0) as on_order_qty
from erp_items i
join erp_v_balance b using (code)
join erp_v_usage   u using (code)
left join erp_v_on_order oo using (code)
where i.active;

-- 重建 view 會把 03_security.sql 收掉的權限還原，這裡要再收一次
revoke all on erp_v_items, erp_v_on_order from anon, authenticated;

-- ---------------------------------------------------------------------
-- 品項主檔要存得下新欄位。舊呼叫沒帶這兩個 key 時保留原值，
-- 不要被 coalesce 成預設值 —— 店長改過的到貨天數不能被一次存檔洗掉。
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
                         is_tea, pack_g, avg_per_day_manual, note, sort_order,
                         lead_days, cover_days, updated_at)
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
          coalesce((p_item->>'lead_days')::int, 3),
          coalesce((p_item->>'cover_days')::int, 14),
          now())
  on conflict (code) do update set
    name = excluded.name, cat = excluded.cat, unit = excluded.unit,
    safe_qty = excluded.safe_qty, cost = excluded.cost, supplier = excluded.supplier,
    is_tea = excluded.is_tea, pack_g = excluded.pack_g,
    avg_per_day_manual = excluded.avg_per_day_manual,
    note = excluded.note, sort_order = excluded.sort_order,
    lead_days  = coalesce((p_item->>'lead_days')::int,  erp_items.lead_days),
    cover_days = coalesce((p_item->>'cover_days')::int, erp_items.cover_days),
    active = true, updated_at = now();

  return jsonb_build_object('ok', true,
    'item', (select to_jsonb(v) from erp_v_items v where v.code = p_item->>'code'));
end $$;

revoke all on function erp_save_item(jsonb) from public, anon;
grant execute on function erp_save_item(jsonb) to authenticated;
