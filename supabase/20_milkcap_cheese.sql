-- =====================================================================
-- 20_milkcap_cheese.sql — 奶蓋配方補上卡夫菲力乳酪
--
-- ★ 還沒執行。等老闆跟店長確認「一杯挖幾克」之後再跑。★
--
-- 問題
--   9/26 匯配方時，奶蓋是按「一鍋 618g ＝ 鮮奶油400＋鮮奶160＋煉乳50＋海鹽8」算的，
--   漏掉成本表上的 **卡夫菲力乳酪 60g**。12 支奶蓋飲料一支都沒有乳酪，所以：
--     ・乳酪永遠不會被扣庫存（叫貨不會提醒、盤點每次對不起來）
--     ・奶蓋成本少算約 0.18 元/杯
--     ・「奶蓋倒掉」記損耗也不會扣乳酪（它讀的就是這份配方）
--
-- 正確的一鍋（老闆 2026-10-02 確認，成本表 AL 欄）
--   愛樂薇鮮奶油 400 ＋ 卡夫菲力乳酪 60 ＋ 鮮奶 160 ＋ 煉乳 50 ＋ 海鹽 8 ＝ 678 g
--
-- ★ 要確認的：一杯挖 50g 還是 45g？成本表上兩種都有寫。
--   下面預設 50g（一鍋 13.56 杯）。若店長說 45g，把 A 區註解掉、改用 B 區。
--
-- 每杯用量 ＝ 一鍋的量 ÷ 一鍋幾杯 ÷ (1 − 耗損)
--   耗損沿用成本表：鮮奶油 10%、乳酪 15%、鮮奶 2%、煉乳 10%、海鹽 3%
--
-- 鮮奶要分兩種：
--   「○○奶蓋」只有奶蓋那份；「○○鮮奶茶奶蓋」還要加鮮奶茶本身的 81.6327
-- =====================================================================

begin;

-- ── A 區：一杯 50 g（一鍋 13.56 杯）──────────────────────────
update erp_recipes set qty = 32.7761 where item_code = 'CRM-01' and pos_name like '%奶蓋%';
update erp_recipes set qty =  4.0970 where item_code = 'SUG-01' and pos_name like '%奶蓋%';
update erp_recipes set qty =  0.6082 where item_code = 'SEA-01' and pos_name like '%奶蓋%';
update erp_recipes set qty = 12.0402 where item_code = 'MLK-01'
   and pos_name like '%奶蓋%' and pos_name not like '%鮮奶茶奶蓋%';
update erp_recipes set qty = 93.6729 where item_code = 'MLK-01'
   and pos_name like '%鮮奶茶奶蓋%';
insert into erp_recipes (pos_name, item_code, qty, scale_by_sweet, deduct)
select distinct pos_name, 'CHS-01', 5.2056, false, true
  from erp_recipes where pos_name like '%奶蓋%'
on conflict (pos_name, item_code) do update set qty = excluded.qty, deduct = true;

-- ── B 區：一杯 45 g（一鍋 15.07 杯）── 要用的話把 A 區註解掉 ──
-- update erp_recipes set qty = 29.4985 where item_code = 'CRM-01' and pos_name like '%奶蓋%';
-- update erp_recipes set qty =  3.6873 where item_code = 'SUG-01' and pos_name like '%奶蓋%';
-- update erp_recipes set qty =  0.5474 where item_code = 'SEA-01' and pos_name like '%奶蓋%';
-- update erp_recipes set qty = 10.8362 where item_code = 'MLK-01'
--    and pos_name like '%奶蓋%' and pos_name not like '%鮮奶茶奶蓋%';
-- update erp_recipes set qty = 92.4689 where item_code = 'MLK-01'
--    and pos_name like '%鮮奶茶奶蓋%';
-- insert into erp_recipes (pos_name, item_code, qty, scale_by_sweet, deduct)
-- select distinct pos_name, 'CHS-01', 4.6851, false, true
--   from erp_recipes where pos_name like '%奶蓋%'
-- on conflict (pos_name, item_code) do update set qty = excluded.qty, deduct = true;

commit;

-- 驗證：12 支都要有 CHS-01，奶蓋本身五樣材料齊全
-- select pos_name, item_code, qty from erp_recipes
--  where pos_name in ('奶蓋','伯爵茶奶蓋','伯爵鮮奶茶奶蓋') order by pos_name, item_code;
-- select count(distinct pos_name) from erp_recipes where item_code = 'CHS-01';  -- 應該 12
