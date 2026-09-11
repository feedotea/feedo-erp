-- =====================================================================
-- 15_order_unit.sql — 叫貨單位可以在 App 裡設定
--
-- order_unit／order_pack 從 01 就有，叫貨頁、到貨、在途量都在用，
-- 但 erp_save_item 不收這兩個欄位，要改只能直接改資料庫（14 的紙杯
-- 論箱就是這樣改的）。這裡讓品項存檔也能帶這兩個 key。
--
-- 規則：
--   * 沒帶 order_unit 這個 key → 兩個欄位都保留原值，舊版前端存檔不會洗掉
--   * order_unit 空白，或跟庫存單位一樣 → 清掉，叫貨就用庫存單位
--   * 有填 order_unit，order_pack（1 個叫貨單位 = 幾個庫存單位）一定要 > 0
--   * 品項還在等貨中不能改：那張單記的是舊單位，改了之後在途量和
--     到貨的換算都會錯，而且畫面上看不出來
--
-- 部署：在 01〜14 之後跑。可重複執行。簽名跟 07 一樣，直接 replace。
-- =====================================================================

create or replace function erp_save_item(p_item jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code   text    := p_item->>'code';
  v_has_ou boolean := p_item ? 'order_unit';
  v_ou     text;
  v_op     numeric;
begin
  perform erp_require_manager();

  if v_has_ou then
    v_ou := nullif(btrim(coalesce(p_item->>'order_unit', '')), '');
    v_op := nullif(p_item->>'order_pack', '')::numeric;
    if v_ou is not null and v_ou = coalesce(p_item->>'unit', '') then
      v_ou := null;                          -- 跟庫存單位一樣，等於沒設
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

  insert into erp_suppliers (name)
  select p_item->>'supplier'
  where coalesce(p_item->>'supplier','') not in ('', '—')
  on conflict (name) do nothing;

  insert into erp_items (code, name, cat, unit, safe_qty, cost, supplier,
                         is_tea, pack_g, avg_per_day_manual, note, sort_order,
                         lead_days, cover_days, order_unit, order_pack, updated_at)
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
          v_ou,
          v_op,
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
    active = true, updated_at = now();

  return jsonb_build_object('ok', true,
    'item', (select to_jsonb(v) from erp_v_items v where v.code = v_code));
end $$;

revoke all on function erp_save_item(jsonb) from public, anon;
grant execute on function erp_save_item(jsonb) to authenticated;
