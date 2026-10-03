-- =====================================================================
-- 22_brew_yield.sql — 茶葉報廢改用「茶湯 ml」填
--
-- 老闆：「報廢通常算茶湯欸」。店員倒掉的是泡好的茶，不是乾茶葉 ——
-- 之前只能填公克，等於要他自己心算「480ml 的茶是幾克茶葉」，
-- 所以他填 480 又按 ml，被系統擋下來（而且擋的理由被手機工具列蓋住）。
--
-- 存一個「1g 茶葉泡得出幾 ml」就換得回去。成本表的泡出量是每 600g：
--   24,000ml → 40 ml/g（紅烏龍、機採紅茶、阿薩姆、伯爵、凍頂、炭焙、迎香）
--   15,000ml → 25 ml/g（比賽工法茶、茉莉綠茶、獅頭機採烏龍茶）
-- 炭焙倒掉 480ml ＝ 480 ÷ 40 ＝ 12g。
--
-- 只有茶葉有這個欄位；其他品項是 null，單位清單就不會出現 ml。
-- 2026-10-03 已在正式庫執行。可重複執行。
-- =====================================================================

alter table erp_items add column if not exists brew_ml_per_g numeric(8,2);

update erp_items set brew_ml_per_g = 40, updated_at = now()
 where code in ('TEA-01','TEA-03','TEA-06','TEA-07','TEA-08','TEA-10','TEA-11',
                'TEA-21','TEA-22','TEA-23');
update erp_items set brew_ml_per_g = 25, updated_at = now()
 where code in ('TEA-02','TEA-04','TEA-09');

-- erp_v_items 要把它回給前端（加在最後面，create or replace 不會噴）
-- 完整定義見 21_tea_blends.sql 之後的版本；這裡只補這一欄。
-- select code, name, brew_ml_per_g from erp_v_items where cat='茶葉' order by code;
