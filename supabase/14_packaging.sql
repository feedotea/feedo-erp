-- =====================================================================
-- 14_packaging.sql — 包材設定（2026-09-11 已在正式庫執行）
--
-- 店長確認的三件事：
--   ・紙杯 1 箱 = 1,000 個（先用這個，還沒跟紙箱或廠商對過）
--   ・每杯飲料都附一支吸管
--   ・兩杯袋和四杯袋分開叫貨
--
-- 吸管共用 cup 角色：跟紙杯同一套規則（飲料杯數扣掉自帶環保杯的），
-- 不用動 erp_pos_import。代價是自帶環保杯的客人如果也拿吸管，那支
-- 不會被扣 —— 環保杯約佔 1%，每月盤點會校正。
--
-- 兩種袋子改走 POS 品項對應（賣一個扣一個）。原本共用的「塑膠袋」
-- 拿掉 bag 角色並下架，否則會跟對應重複扣；它有 94 筆舊扣料紀錄，
-- 只下架不刪。
--
-- 可重複執行。
-- =====================================================================

begin;

-- 0) 紙杯：叫貨改論箱，1 箱 = 1,000 個（店長說先用這個，還沒跟紙箱或廠商確認）
update erp_items set order_unit = '箱', order_pack = 1000, updated_at = now()
 where code = 'PKG-01';

-- 1) 吸管：每杯飲料一支，跟紙杯一起扣。
--    單位原本是「箱」，每杯扣 1 箱就錯了 —— 改成「支」。它沒有任何進出紀錄，改單位安全。
--    共用 cup 這個角色：跟紙杯同一套規則（飲料杯數，扣掉自帶環保杯的），
--    不用去動匯入函式。一箱幾支還不知道，叫貨先用「支」。
update erp_items
   set unit = '支', pos_role = 'cup', updated_at = now()
 where code = 'PKG-03'
   and not exists (select 1 from erp_stock_moves where item_code = 'PKG-03');

-- 2) 兩杯袋、四杯袋分開叫貨 → 拆成兩個品項，用 POS 品項對應「賣一個扣一個」。
insert into erp_items (code, name, cat, unit, cost, safe_qty, lead_days, cover_days, active, updated_at)
values ('PKG-08','兩杯袋','包材','個',0,0,3,14,true,now()),
       ('PKG-09','四杯袋','包材','個',0,0,3,14,true,now())
on conflict (code) do nothing;

insert into erp_pos_item_map (pos_name, item_code, ignored, category, mapped_at)
values ('兩杯袋','PKG-08',false,'袋子',now()),
       ('四杯袋','PKG-09',false,'袋子',now())
on conflict (pos_name) do update set item_code = excluded.item_code, ignored = false, mapped_at = now();

-- 3) 原本兩種袋子共用的「塑膠袋」下架：拿掉 bag 角色，不然會跟上面重複扣。
--    它有 94 筆舊的扣料紀錄，只下架不刪，舊帳才不會斷。
update erp_items set pos_role = null, active = false, updated_at = now()
 where code = 'PKG-04';

commit;
