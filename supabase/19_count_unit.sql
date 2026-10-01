-- =====================================================================
-- 19_count_unit.sql — 盤點單位（「一瓶/一包多少」可以自己設）
--
-- 為什麼要這一支
--   盤點要用數得出來的單位。茶葉早就有（一包 100g），鮮奶和鮮奶油靠
--   叫貨單位是「瓶」也順便吃到了，但蔗糖液（一箱 5kg×4瓶）和煉奶
--   （一箱 2kg×8包）的叫貨單位是「箱」—— 總不能叫店長填 0.75 箱，
--   也不能叫他數 106,958 ml。
--
--   所以品項上多一組「盤點單位 + 1 個盤點單位 = 幾個庫存單位」。
--   叫貨照樣論箱，庫存和配方照樣存 ml／g，**成本完全不受影響**。
--
-- 盤點時的優先順序（前端 stPack）：
--   1. 有設 count_unit/count_pack → 用它
--   2. 茶葉 → 包（pack_g）
--   3. 叫貨單位是單罐單包（瓶／包／罐／袋／捲／條／盒）→ 用叫貨單位
--   4. 都沒有 → 庫存單位
--
-- 部署：15 之後。可重複執行。
-- =====================================================================

begin;

alter table erp_items add column if not exists count_unit text;
alter table erp_items add column if not exists count_pack numeric(12,3);

-- 欄位加在最後面，所以 create or replace 不會噴 cannot change name of view column
create or replace view erp_v_items as
select
  i.code, i.name, i.cat, i.unit, i.safe_qty, i.cost, i.supplier,
  i.is_tea, i.pack_g, i.note, i.sort_order, i.avg_per_day_manual,
  i.pos_role, i.order_unit, i.order_pack,
  i.lead_days, i.cover_days,
  b.bal,
  case when u.days_with_data >= 14 and u.avg_actual > 0
       then round(u.avg_actual, 3)
       else i.avg_per_day_manual
  end as avg_per_day,
  (u.days_with_data >= 14 and u.avg_actual > 0) as avg_is_actual,
  exists (select 1 from erp_orders o
          where o.item_code = i.code and o.status = 'pending') as on_order,
  coalesce(oo.on_order_qty, 0) as on_order_qty,
  i.count_unit, i.count_pack
from erp_items i
join erp_v_balance b using (code)
join erp_v_usage   u using (code)
left join erp_v_on_order oo using (code)
where i.active;

revoke all on erp_v_items from anon, authenticated;

-- 品項存檔收這兩個新 key。沒帶 key 就保留原值（跟 order_unit 同一套規則），
-- 舊版前端存檔不會把店長設好的盤點單位洗掉。
create or replace function erp_save_item(p_item jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code   text    := p_item->>'code';
  v_has_ou boolean := p_item ? 'order_unit';
  v_has_cu boolean := p_item ? 'count_unit';
  v_ou     text;
  v_op     numeric;
  v_cu     text;
  v_cp     numeric;
begin
  perform erp_require_manager();

  if v_has_ou then
    v_ou := nullif(btrim(coalesce(p_item->>'order_unit', '')), '');
    v_op := nullif(p_item->>'order_pack', '')::numeric;
    if v_ou is not null and v_ou = coalesce(p_item->>'unit', '') then
      v_ou := null;
    end if;
    if v_ou is null then
      v_op := null;
    elsif v_op is null or v_op <= 0 then
      raise exception '叫貨單位「%」要填 1 % 等於幾%', v_ou, v_ou, coalesce(p_item->>'unit', '個')
        using errcode = '22023';
    end if;
    if exists (select 1 from erp_items i
               where i.code = v_code
                 and (i.order_unit is distinct from v_ou or i.order_pack is distinct from v_op))
       and exists (select 1 from erp_orders o
                   where o.item_code = v_code and o.status = 'pending') then
      raise exception '這個品項還在等貨中，按到貨或取消標記之後再改叫貨單位'
        using errcode = '22023';
    end if;
  end if;

  if v_has_cu then
    v_cu := nullif(btrim(coalesce(p_item->>'count_unit', '')), '');
    v_cp := nullif(p_item->>'count_pack', '')::numeric;
    if v_cu is not null and v_cu = coalesce(p_item->>'unit', '') then
      v_cu := null;                          -- 跟庫存單位一樣，等於沒設
    end if;
    if v_cu is null then
      v_cp := null;
    elsif v_cp is null or v_cp <= 0 then
      raise exception '盤點單位「%」要填 1 % 等於幾%', v_cu, v_cu, coalesce(p_item->>'unit', '個')
        using errcode = '22023';
    end if;
  end if;

  insert into erp_suppliers (name)
  select p_item->>'supplier'
  where coalesce(p_item->>'supplier','') not in ('', '—')
  on conflict (name) do nothing;

  insert into erp_items (code, name, cat, unit, safe_qty, cost, supplier,
                         is_tea, pack_g, avg_per_day_manual, note, sort_order,
                         lead_days, cover_days, order_unit, order_pack,
                         count_unit, count_pack, updated_at)
  values (v_code,
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
          v_ou, v_op, v_cu, v_cp,
          now())
  on conflict (code) do update set
    name = excluded.name, cat = excluded.cat, unit = excluded.unit,
    safe_qty = excluded.safe_qty, cost = excluded.cost, supplier = excluded.supplier,
    is_tea = excluded.is_tea, pack_g = excluded.pack_g,
    avg_per_day_manual = excluded.avg_per_day_manual,
    note = excluded.note, sort_order = excluded.sort_order,
    lead_days  = coalesce((p_item->>'lead_days')::int,  erp_items.lead_days),
    cover_days = coalesce((p_item->>'cover_days')::int, erp_items.cover_days),
    order_unit = case when v_has_ou then v_ou else erp_items.order_unit end,
    order_pack = case when v_has_ou then v_op else erp_items.order_pack end,
    count_unit = case when v_has_cu then v_cu else erp_items.count_unit end,
    count_pack = case when v_has_cu then v_cp else erp_items.count_pack end,
    active = true, updated_at = now();

  return jsonb_build_object('ok', true,
    'item', (select to_jsonb(v) from erp_v_items v where v.code = v_code));
end $$;

revoke all on function erp_save_item(jsonb) from public, anon;
grant execute on function erp_save_item(jsonb) to authenticated;

-- 這兩樣就是當初逼出這個欄位的：叫貨論箱，但盤點要數瓶／包
update erp_items set count_unit = '瓶', count_pack = 3846.25, updated_at = now()
 where code = 'PKG-06';          -- 蔗糖液：一箱 5kg×4瓶 ＝ 15,385ml
update erp_items set count_unit = '包', count_pack = 2000, updated_at = now()
 where code = 'SUG-01';          -- 飛燕煉奶：一箱 2kg×8包 ＝ 16,000g

commit;

-- 驗證
-- select code, name, unit, order_unit, order_pack, count_unit, count_pack
--   from erp_items where code in ('PKG-06','SUG-01','MLK-01');
