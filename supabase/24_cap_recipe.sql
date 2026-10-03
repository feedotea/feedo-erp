-- =====================================================================
-- 24_cap_recipe.sql — 奶蓋配方（店員也讀得到的版本）
--
-- 記損耗的第一顆鍵是「奶蓋（整鍋倒掉）」，它要靠配方才建得出來。
-- 但前端拿配方是打 erp_recipes_config，那支第一行是 erp_require_manager
-- —— 所以店員打開記損耗根本看不到那顆鍵，而且前端是 .catch(()=>{})，
-- 畫面上連一句錯誤都沒有，看起來就是「本來就沒有那顆」。
-- 結果：店員倒掉的奶蓋從來沒被記錄過，鮮奶油／乳酪／鮮奶／煉乳／海鹽
-- 五樣一克都沒扣（一鍋材料約 126 元）。
--
-- 這支只回「用哪幾樣、各幾克、扣不扣」，不回成本也不回單價 ——
-- 跟庫存總值、進貨單價、損耗金額同一條線：數量給所有人，錢只給店長。
--
-- 品名由前端傳進來（前端常數 CAP_NAME），函式裡刻意不寫中文字串 ——
-- SQL Editor 貼上時少了 LC_ALL=en_US.UTF-8，中文會變亂碼而且不會報錯。
--
-- 部署：可重複執行，沒有相依。
-- =====================================================================

create or replace function erp_cap_recipe(p_name text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform erp_require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'item_code', r.item_code,
             'qty',       r.qty,
             'deduct',    r.deduct
           ) order by r.qty desc)
    from erp_recipes r
    where r.pos_name = p_name
  ), '[]'::jsonb);
end $$;

revoke all    on function erp_cap_recipe(text) from public, anon;
grant execute on function erp_cap_recipe(text) to authenticated;
