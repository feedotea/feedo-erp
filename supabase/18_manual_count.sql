-- =====================================================================
-- 18_manual_count.sql — 吸管、四杯袋改成「月盤點」（停掉自動扣料）
--
-- 老闆的決定（2026-10-01）：這幾樣包材不要自動扣，每個月盤一次就好。
--
-- 為什麼吸管該停
--   它共用 cup 角色，規則是「每杯飲料扣一支」。這是假設，不是事實：
--   自帶環保杯的人也可能拿吸管、內用不一定用、珍珠要換粗吸管。
--   加上單位從「箱」改成「支」時庫存沒跟著換算，現在帳面是 -8,285 支。
--
-- 四杯袋不太一樣（留著這段，之後想改回去看得懂）
--   它走 POS 品項對應，客人買一個就扣一個 —— 這個扣法其實是準的。
--   -223 是因為進貨從來沒記，不是扣錯。停掉之後袋子的數字只有盤點那天是對的。
--
-- 停掉之後的影響（兩樣都一樣）
--   ・月結的物料成本不含這些（盤點寫的是「調整」，cogs 只算 brew/use）
--   ・叫貨頁算不出「還能撐幾天」，改用安全庫存判斷
--
-- 杯膜（PKG-12）本來就沒掛角色，不用動。紙杯（PKG-01）維持自動扣。
-- 可重複執行。
-- =====================================================================

begin;

-- 1) 吸管：拿掉 cup 角色就不再自動扣
update erp_items
   set pos_role = null, updated_at = now()
 where code = 'PKG-03';

-- 2) 四杯袋：POS 品項對應改成「不對應」
--    （等同在「🔗 POS 品項對應」裡選「— 不對應 —」）
update erp_pos_item_map
   set item_code = null, ignored = false, mapped_at = now()
 where pos_name = '四杯袋';

commit;

-- 驗證
-- select code, name, unit, pos_role from erp_items where code in ('PKG-01','PKG-03','PKG-12');
--   → 只有 PKG-01 應該還有 'cup'
-- select pos_name, item_code, ignored from erp_pos_item_map where pos_name like '%杯袋%';
--   → 四杯袋 item_code 應該是 null；兩杯袋不動
