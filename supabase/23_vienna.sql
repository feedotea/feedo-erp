-- =====================================================================
-- 23_vienna.sql — 維也納奶茶（四葉草系列）配方
--
-- 老闆提供的配方卡「四葉草系列奶茶」：
--   阿薩姆奶茶（糖冰固定）  原味 / 巧克力
--     阿薩姆茶湯 250、四葉草奶粉 22、巧克力醬 15g（只有巧克力版）、
--     蔗糖 3分糖、冰塊 刻度500
--   伯爵奶茶（糖冰固定）：伯爵茶湯 250、四葉草奶粉 22、3分糖、冰刻度500
--
-- POS 上賣的是「維也納奶茶（原味)」「維也納奶茶（巧克力）」——
-- 60 天 495 杯，但一直**沒有配方**，奶粉和茶葉從來沒被扣過。
--
-- 換算
--   茶葉 250ml ÷ 40 ÷ 0.95 = 6.5789g（1:40，5% 耗損）
--   奶粉 22 ÷ 0.97 = 22.6804g（3% 耗損）
--   糖   全糖 60cc × 3分 = 18cc，固定不跟甜度縮（卡片寫「糖冰固定」）
--
-- ⚠ 巧克力醬的成本還是 0 —— 老闆還沒給一罐多少錢／幾 g。
-- ⚠ POS 名稱用 like '維也納%' 抓，因為「（原味)」的括號一邊全形一邊半形，手打容易錯。
-- 2026-10-03 已在正式庫執行。
-- =====================================================================

insert into erp_items (code, name, cat, unit, cost, safe_qty, lead_days, cover_days, active, updated_at)
select 'TOP-' || lpad(((coalesce(max(substring(code from 5)::int),0))+1)::text,2,'0'),
       '巧克力醬', '配料', 'g', 0, 0, 3, 14, true, now()
  from erp_items where code like 'TOP-%'
on conflict (code) do nothing;

delete from erp_recipes where pos_name like '維也納%';

insert into erp_recipes (pos_name, item_code, qty, scale_by_sweet, deduct)
select p.pos_name, v.code, v.qty, false, v.deduct
  from (select distinct pos_name from erp_pos_sales where pos_name like '維也納%') p
  cross join (values ('TEA-06', 6.5789, false),    -- 阿薩姆茶葉，庫存由煮茶頁扣
                     ('MLK-02', 22.6804, true),    -- 四葉北海道奶粉
                     ('PKG-06', 18.0, true)        -- 蔗糖液 3 分糖
             ) as v(code, qty, deduct);

insert into erp_recipes (pos_name, item_code, qty, scale_by_sweet, deduct)
select p.pos_name, (select code from erp_items where name='巧克力醬' limit 1), 15.0, false, true
  from (select distinct pos_name from erp_pos_sales
         where pos_name like '維也納%' and pos_name like '%巧克力%') p;
