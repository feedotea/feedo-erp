-- =====================================================================
-- 17_waste_list.sql — 最近的損耗明細（庫存頁要看得到）
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
             'day',  m.occurred_on,
             'code', m.item_code,
             'name', i.name,
             'qty',  -m.qty_delta,          -- 存的是負數，給前端正數比較好讀
             'unit', i.unit,
             'note', m.note,                -- 「過期（填 2斤）」這種整串
             'who',  coalesce(s.name, ''),
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

-- 驗證
-- select erp_waste_list();        -- 最近 30 天
-- select erp_waste_list(365);     -- 整年，確認舊資料也讀得到
