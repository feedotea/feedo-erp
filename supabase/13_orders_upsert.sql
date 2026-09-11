-- =====================================================================
-- 13_orders_upsert.sql — 訂單層改用自然鍵 upsert，不再「整天刪掉重寫」
--
-- 10_orders_fix.sql 為了躲開「訂單編號會重複」，改成每天整批刪掉再寫。
-- 手動匯入整個月的檔沒問題，但每天自動匯入就有隱患：微碧的日報表
-- 區間是「前一天 18:1x 到當天 18:2x」。如果哪天有客人在截止後才結帳，
-- 隔天那份檔就會帶到前一天的一小段 —— 整天刪掉重寫，前一天就只剩
-- 那一小段，當天其餘的訂單全部消失，而且不會報錯。
--
-- 到 2026-09-10 為止還沒發生過（店在截止前就打烊了），但這是運氣。
--
-- 唯一鍵改成（日期、訂單編號、付款時間）。訂單編號單獨不唯一
-- （8/15 有兩張 499567），加上付款時間就唯一了（那兩張差 1 小時 45 分）。
-- 用 upsert：同一張單重匯是更新，不同檔各自帶到的單互不影響。
--
-- 部署：在 12_recipes.sql 之後跑。可重複執行。
-- =====================================================================

create unique index if not exists erp_pos_orders_nat_key
  on erp_pos_orders (sales_on, order_no, coalesce(paid_at, timestamp '1970-01-01'));

create or replace function erp_pos_save_orders(p_orders jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  perform erp_require_manager();
  if p_orders is null or jsonb_array_length(p_orders) = 0 then
    return jsonb_build_object('ok', true, 'saved', 0);
  end if;

  insert into erp_pos_orders (sales_on, order_no, paid_at, total, items, channel, updated_at)
  -- 同一批裡如果同一張單出現兩次，只留一筆，不然 upsert 會撞自己
  select distinct on (d, no, coalesce(at, timestamp '1970-01-01'))
         d, no, at, total, items, channel, now()
  from (
    select (o->>'date')::date as d, o->>'no' as no,
           nullif(o->>'at','')::timestamp as at,
           coalesce((o->>'total')::numeric, 0) as total,
           coalesce((o->>'items')::numeric, 0) as items,
           nullif(o->>'channel','') as channel
    from jsonb_array_elements(p_orders) o
    where nullif(o->>'no','') is not null and nullif(o->>'date','') is not null
  ) x
  order by d, no, coalesce(at, timestamp '1970-01-01')
  on conflict (sales_on, order_no, coalesce(paid_at, timestamp '1970-01-01')) do update set
    total = excluded.total, items = excluded.items,
    channel = excluded.channel, updated_at = now();

  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'saved', n);
end $$;

revoke all on function erp_pos_save_orders(jsonb) from public, anon;
grant execute on function erp_pos_save_orders(jsonb) to authenticated;
