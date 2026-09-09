-- =====================================================================
-- 10_orders_fix.sql — 訂單編號不是唯一的
--
-- 原本用 (sales_on, order_no) 當主鍵。錯了：微碧的訂單編號會重複，
-- 2026-08-15 就有兩張不同的單都叫 499567（$258 和 $525，付款時間
-- 差一小時四十五分）。整批 upsert 撞到同一個鍵，Postgres 直接丟
-- 「ON CONFLICT DO UPDATE command cannot affect row a second time」，
-- 那一天 179 筆全部寫不進去 —— 而且是靜靜地失敗，只有對數字才看得出來。
--
-- 改成跟 erp_pos_sales 一樣的做法：訂單是 CSV 的每日快照，重匯就
-- 整天換掉，不做 upsert。沒有唯一鍵要維護，也就沒有撞鍵問題。
--
-- 已知的小誤差：明細（erp_pos_sales）沒有訂單流水號，同一天同編號
-- 的兩張單在算「一單幾件」時會被併成一張。3250 筆裡有 1 筆，
-- 不值得為了 POS 的怪癖去建一套訂單識別。
--
-- 部署：在 09_labor.sql 之後跑。可重複執行。
-- =====================================================================

alter table erp_pos_orders add column if not exists id uuid default gen_random_uuid();
update erp_pos_orders set id = gen_random_uuid() where id is null;
alter table erp_pos_orders alter column id set not null;

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'erp_pos_orders_pkey') then
    alter table erp_pos_orders drop constraint erp_pos_orders_pkey;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'erp_pos_orders_id_pk') then
    alter table erp_pos_orders add constraint erp_pos_orders_id_pk primary key (id);
  end if;
end $$;

create index if not exists erp_pos_orders_no_idx on erp_pos_orders (sales_on, order_no);

-- ---------------------------------------------------------------------
-- 存訂單：整天換掉，不 upsert。
-- 一次呼叫可能含多天（單日檔走這條），所以先算出這批涵蓋哪些日子。
-- ---------------------------------------------------------------------
create or replace function erp_pos_save_orders(p_orders jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  dates date[];
  n     int := 0;
begin
  perform erp_require_manager();
  if p_orders is null or jsonb_array_length(p_orders) = 0 then
    return jsonb_build_object('ok', true, 'saved', 0);
  end if;

  select array_agg(distinct (o->>'date')::date)
    into dates
    from jsonb_array_elements(p_orders) o
   where nullif(o->>'date','') is not null;

  if dates is null then
    return jsonb_build_object('ok', true, 'saved', 0);
  end if;

  delete from erp_pos_orders where sales_on = any(dates);

  insert into erp_pos_orders (sales_on, order_no, paid_at, total, items, channel, updated_at)
  select (o->>'date')::date, o->>'no',
         nullif(o->>'at','')::timestamp,
         coalesce((o->>'total')::numeric, 0),
         coalesce((o->>'items')::numeric, 0),
         nullif(o->>'channel',''), now()
  from jsonb_array_elements(p_orders) o
  where nullif(o->>'no','') is not null and nullif(o->>'date','') is not null;

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'saved', n, 'days', array_length(dates, 1));
end $$;

revoke all on function erp_pos_save_orders(jsonb) from public, anon;
grant execute on function erp_pos_save_orders(jsonb) to authenticated;
