-- =====================================================================
-- 17_waste_list.sql — 最近的損耗明細（庫存頁要看得到）＋ 刪掉記錯的那筆
--
-- 為什麼要這一支
--   損耗一直寫得進去（erp_stock_moves kind='waste'），但**全站沒有任何
--   一頁讀得出來**：月結的 cogs 故意只算 brew/use（損耗不該算進用量，
--   不然預測會失真），所以記完之後畫面上只有庫存數字少一點、外加一個
--   閃兩秒的提示。店長因此覺得「按了沒反應」，也沒辦法月底檢討哪樣
--   東西一直在倒掉。
--
-- 權限
--   erp_require_staff：店員自己記的要看得到。
--   但「金額」只給店長／老闆 —— 成本是錢，跟庫存總值、進貨單價同一條線。
--
-- 部署順序：16 之後。可重複執行。
-- =====================================================================

create or replace function erp_waste_list(p_days int default 30)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  mgr boolean := erp_is_manager();
begin
  perform erp_require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',   m.id,                   -- 要刪的時候用
             'day',  m.occurred_on,
             'code', m.item_code,
             'name', i.name,
             'qty',  -m.qty_delta,          -- 存的是負數，給前端正數比較好讀
             'unit', i.unit,
             'note', m.note,                -- 「過期（填 2斤）」這種整串
             'who',  coalesce(s.name, ''),
             'mine', (m.created_by = auth.uid()),   -- 自己記的才給刪
             -- 店員看不到錢
             'cost', case when mgr then round(-m.qty_delta * i.cost, 1) else null end)
           order by m.occurred_on desc, m.created_at desc)
      from erp_stock_moves m
      join erp_items i on i.code = m.item_code
      left join erp_staff s on s.user_id = m.created_by
     where m.kind = 'waste'
       and m.occurred_on >= erp_today() - p_days
  ), '[]'::jsonb);
end $$;

revoke all on function erp_waste_list(int) from public, anon;
grant execute on function erp_waste_list(int) to authenticated;

-- ---------------------------------------------------------------------
-- 刪掉記錯的那一筆
--
-- 庫存餘額是 erp_v_balance 即時加總 erp_stock_moves 算的，所以把那筆
-- 刪掉，數量就自己加回去了，不用再補一筆反向異動（補反向的話庫存對，
-- 但損耗清單會多出一筆看不懂的東西）。
--
-- 只開放 kind='waste'：進貨、煮茶、盤點都不能從這裡刪。
-- 店員只能刪自己記的；店長／老闆誰的都能刪
-- （跟盤點同一個想法：事後看得到，而不是事前擋住）。
-- ---------------------------------------------------------------------
create or replace function erp_waste_delete(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := erp_require_staff();
  mv  erp_stock_moves;
begin
  select * into mv from erp_stock_moves where id = p_id;
  if not found then
    raise exception '找不到這筆紀錄（可能已經刪過了）' using errcode = '22023';
  end if;
  if mv.kind <> 'waste' then
    raise exception '只能刪損耗，這筆是 %', mv.kind using errcode = '22023';
  end if;
  if not erp_is_manager() and mv.created_by <> uid then
    raise exception '只能刪自己記的，其他的請店長處理' using errcode = '42501';
  end if;

  delete from erp_stock_moves where id = p_id;

  return jsonb_build_object('ok', true, 'code', mv.item_code,
    'item', (select to_jsonb(v) from erp_v_items v where v.code = mv.item_code));
end $$;

revoke all on function erp_waste_delete(uuid) from public, anon;
grant execute on function erp_waste_delete(uuid) to authenticated;

-- 驗證
-- select erp_waste_list();        -- 最近 30 天，每筆要有 id 和 mine
-- select erp_waste_list(365);     -- 整年，確認舊資料也讀得到
-- select erp_waste_delete('那筆的 id');  -- 刪完回庫存頁，數量應該加回去了
