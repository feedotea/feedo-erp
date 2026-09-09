-- =====================================================================
-- FEEDO ERP · 權限
--
-- 原則：base table 和 view 對前端「完全不可見」，一律 deny-all。
-- 前端唯一的入口是 erp_* function（SECURITY DEFINER，內部自己驗身分）。
-- 這樣就算 anon key 外流，沒有 ERP 帳號也做不了任何事。
-- =====================================================================

-- ---- 1. 所有表開 RLS，且不建立任何 policy → 預設全部拒絕 ----
alter table erp_staff       enable row level security;
alter table erp_suppliers   enable row level security;
alter table erp_items       enable row level security;
alter table erp_stock_moves enable row level security;
alter table erp_orders      enable row level security;
alter table erp_expenses    enable row level security;
alter table erp_revenue     enable row level security;

alter table erp_staff       force row level security;
alter table erp_suppliers   force row level security;
alter table erp_items       force row level security;
alter table erp_stock_moves force row level security;
alter table erp_orders      force row level security;
alter table erp_expenses    force row level security;
alter table erp_revenue     force row level security;

-- ---- 2. 直接把表和 view 的權限收掉，PostgREST 就看不到它們 ----
revoke all on erp_staff, erp_suppliers, erp_items, erp_stock_moves,
              erp_orders, erp_expenses, erp_revenue
  from anon, authenticated;

revoke all on erp_v_balance, erp_v_usage, erp_v_items
  from anon, authenticated;

-- ---- 3. 只開放 RPC，且只給登入者 ----
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'erp\_%'
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- 內部輔助函式連 authenticated 都不用直接呼叫
revoke execute on function erp_require_staff()   from authenticated;
revoke execute on function erp_require_manager() from authenticated;
revoke execute on function erp_is_staff()       from authenticated;
revoke execute on function erp_is_manager()     from authenticated;

-- ---------------------------------------------------------------------
-- 4. 建立第一個帳號（在 Supabase Dashboard → Authentication 先加使用者，
--    再回來把 user_id 填進去執行）
-- ---------------------------------------------------------------------
-- insert into erp_staff (user_id, name, role)
-- select id, 'YOUR NAME', 'owner' from auth.users where email = 'you@example.com'
-- on conflict (user_id) do update set role = 'owner', active = true;
