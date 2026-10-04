-- =====================================================================
-- 26_costco_milk.sql — 奶蓋改用好市多（科克蘭）鮮奶
--
-- 老闆：「奶蓋的配方是這個牛奶」。好市多 1.89L × 2 瓶 269 元
-- → 269 / 3,780ml = 0.071164 /ml（瑞穗 0.084402，便宜 15.7%）。
--
-- 只有奶蓋那段換，鮮奶茶基底維持瑞穗：
--   12.0402 ml × 6 支  純茶類奶蓋 ＋「加購奶蓋」→ 整列都是奶蓋的量，直接改掛
--   93.6729 ml × 6 支  鮮奶茶奶蓋 = 基底 81.6327 ＋ 奶蓋 12.0402
--                      → erp_recipes 主鍵是 (pos_name, item_code)，一列一個品項，
--                        所以要拆成兩列：瑞穗 81.6327 ＋ 好市多 12.0402
--   81.6327 ml × 6 支  鮮奶茶基底 → 不動
--
-- ⚠ MLK-03 老闆已經在品項編輯裡建好了（科克蘭冷藏全脂牛乳 1.89公升），
--   但兩個欄位要改，兩個都是踩過的坑：
--     1. 庫存單位填「瓶」—— 配方要扣 12.0402 ml，單位是瓶就會扣成 12 瓶。
--        跟 2026-10-03 青森蘋果汁被改成「瓶」同一個事故。
--        庫存單位一律用配方在用的單位（ml），要好盤請設「盤點單位」。
--     2. 成本填 189 —— 那是把 1.89 公升看成價錢了。一瓶 134.5，每 ml 0.071164。
--   名稱保留老闆取的，比較精確。
--
-- ⚠ 已經盤過一筆「1 瓶」。改成 ml 之後那個 1 會變成 1 ml，
--   所以補一筆 stocktake +1,889 把它校正成 1,890 ml（＝1 瓶）。
--
-- ⚠ 中文一律用 chr() 拼，不寫字面值 —— SQL Editor 貼上時少了
--   LC_ALL=en_US.UTF-8，中文會變亂碼而且不會報錯。
--
-- 影響：奶蓋一杯鮮奶 1.0162 → 0.8568，奶蓋一杯材料 9.28 → 9.12。
-- 部署：可重複執行（校正那筆用固定 uuid，重跑不會變兩筆）。
-- =====================================================================

do $$
declare n1 int; n2 int; n3 int; bal numeric; uid uuid;
begin
  select user_id into uid from erp_staff where role = 'owner' limit 1;

  -- 單位改 ml、成本改每 ml、補上盤點單位（瓶）和叫貨單位（組 ＝ 2 瓶）
  update erp_items set
    unit        = 'ml',
    cost        = 0.071164,
    safe_qty    = 1890,                      -- 一瓶
    count_unit  = chr(29942),  count_pack = 1890,    -- 盤點數「瓶」
    order_unit  = chr(32068),  order_pack = 3780,    -- 叫貨論「組」＝ 2 瓶
    avg_per_day_manual = 340                 -- 奶蓋一天約 28 杯 × 12.04ml
  where code = 'MLK-03';

  -- 盤了 1「瓶」，改單位之後變成 1 ml，補到 1,890 ml
  select coalesce(sum(qty_delta),0) into bal from erp_stock_moves where item_code='MLK-03';
  if bal > 0 and bal < 100 then
    insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, note, created_by)
    values ('26c05c00-0000-4000-8000-000000000001', 'MLK-03', 'stocktake',
            1890 - bal, current_date,
            chr(21934)||chr(20301)||chr(30001)||chr(29942)||chr(25913)||chr(28858)||chr(32)||chr(109)||chr(108)||chr(32)||chr(30340)||chr(26657)||chr(27491)||chr(65288)||chr(49)||chr(32)||chr(29942)||chr(32)||chr(61)||chr(32)||chr(49)||chr(44)||chr(56)||chr(57)||chr(48)||chr(109)||chr(108)||chr(65289),
            uid)
    on conflict (id) do nothing;
  end if;

  -- 鮮奶茶奶蓋：先把奶蓋那 12.0402 拆出來掛好市多
  insert into erp_recipes (pos_name, item_code, qty, scale_by_sweet, deduct)
  select pos_name, 'MLK-03', 12.0402, scale_by_sweet, deduct
    from erp_recipes where item_code='MLK-01' and qty = 93.6729
  on conflict (pos_name, item_code) do update set qty = excluded.qty;
  get diagnostics n1 = row_count;

  -- 原本那列只留基底，維持瑞穗
  update erp_recipes set qty = 81.6327 where item_code='MLK-01' and qty = 93.6729;
  get diagnostics n2 = row_count;

  -- 純茶類奶蓋和「加購奶蓋」整列都是奶蓋的量，直接改掛好市多
  update erp_recipes set item_code='MLK-03' where item_code='MLK-01' and qty = 12.0402;
  get diagnostics n3 = row_count;

  raise notice 'split=% rebase=% moved=%', n1, n2, n3;   -- 預期 6 / 6 / 6
end $$;
