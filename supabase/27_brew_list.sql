-- =====================================================================
-- 27_brew_list.sql — 煮茶紀錄查詢
--
-- 老闆要求「需要查詢及匯出紀錄表功能」。
-- 煮茶一直寫得進 erp_stock_moves（kind='brew'），但**全站沒有一頁讀得出來**
-- —— 跟損耗 2026-10-01 之前一樣的毛病：寫得進去、看不到，
-- 所以記錯了也沒人發現，月盤點才會冒出來。
--
-- 拼茶要還原成「茶桶」：erp_log_brew 看到拼茶會改扣裡面的原料，
-- 所以 erp_stock_moves 上留的是迎香／金萱／阿薩姆，不是「紅烏龍（拼）」。
-- 但 buckets 欄位存的是當時按的桶數，而且同一次登記的原料桶數一樣，
-- 所以用 (日期, 桶數, 建立時間) 分組就還原得回來 —— 這裡直接把原料列出來，
-- 另外標上它屬於哪一個茶桶，店長看得懂、匯出去也對得起來。
--
-- 金額只給店長／老闆（跟損耗、庫存總值同一條線）。
-- 部署：可重複執行。
-- =====================================================================

create or replace function erp_brew_list(p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  mgr boolean := erp_is_manager();
begin
  perform erp_require_staff();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'bad date range';
  end if;
  if p_to - p_from > 400 then
    raise exception 'range too long';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'day',     m.occurred_on,
             'code',    m.item_code,
             'name',    i.name,
             'buckets', m.buckets,
             'qty',     -m.qty_delta,
             'unit',    i.unit,
             'blend',   b.blend_code,
             'blend_name', bi.name,
             'who',     coalesce(s.name, ''),
             'cost',    case when mgr then round(-m.qty_delta * i.cost, 1) else null end)
           order by m.occurred_on desc, i.name)
      from erp_stock_moves m
      join erp_items i on i.code = m.item_code
      left join erp_staff s on s.user_id = m.created_by
      -- 這支原料是哪個茶桶拼出來的（一種原料可能屬於多個茶桶，取第一個）
      left join lateral (
        select t.blend_code from erp_tea_blends t
         where t.part_code = m.item_code
         order by t.blend_code limit 1
      ) b on true
      left join erp_items bi on bi.code = b.blend_code
     where m.kind = 'brew'
       and m.occurred_on between p_from and p_to
  ), '[]'::jsonb);
end $$;

revoke all    on function erp_brew_list(date, date) from public, anon;
grant execute on function erp_brew_list(date, date) to authenticated;
