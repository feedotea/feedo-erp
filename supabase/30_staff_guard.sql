-- =====================================================================
-- 30_staff_guard.sql — 店員送來的「錢」一律忽略
--
-- 原則是「真正的線畫在後端」。前端對店員已經藏了營收欄和進貨單價欄，
-- 但這兩支函式的門是 erp_require_staff，欄位有帶就照寫：
--   erp_log_brew  p_revenue   → 覆蓋 erp_revenue（連自動匯入的數字都會被蓋）
--   erp_log_move  p_unit_cost → 用移動平均改 erp_items.cost（店員看不到成本卻能改成本）
-- 店員帳號自己呼叫 RPC 就走得到。
--
-- 改法：不是 manager 就把那兩個參數當 null。桶數、進貨數量照常寫入，
-- 不報錯 —— 舊版前端或離線佇列裡的舊請求不會因此失敗。
-- 店長／老闆／自動匯入（manager）行為一字不變。
--
-- 簽名不變，create or replace 直接蓋，不會多出多載。可重複執行。
-- 貼之前 LC_ALL=en_US.UTF-8 pbcopy，貼完用檔尾的查詢驗一次。
-- =====================================================================

create or replace function erp_log_brew(
  p_rows    jsonb,
  p_date    date    default null,
  p_revenue numeric default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := erp_require_staff();
  d    date := coalesce(p_date, erp_today());
  -- 營收只有店長能寫。店員帶了就當沒帶，桶數照常記。
  rev  numeric := case when erp_is_manager() then p_revenue end;
  r    jsonb;
  n    int  := 0;
begin
  if d > erp_today() then
    raise exception '不能登記未來日期' using errcode = '22007';
  end if;

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    if exists (select 1 from erp_tea_blends b where b.blend_code = r->>'code') then
      -- 拼茶：一桶拆成兩筆原料。id 由前端 id ＋ 原料代號算出來，重送不會變兩筆。
      insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, buckets, note, created_by)
      select md5((r->>'id') || b.part_code)::uuid,
             b.part_code,
             'brew',
             -((r->>'buckets')::numeric * b.grams),
             d,
             -- 桶數只記第一筆，畫面才不會算成兩倍
             case when b.part_code = (select min(part_code) from erp_tea_blends
                                       where blend_code = r->>'code')
                  then (r->>'buckets')::numeric end,
             '拼茶 ' || (select name from erp_items where code = r->>'code'),
             uid
        from erp_tea_blends b
       where b.blend_code = r->>'code' and (r->>'buckets')::numeric > 0
      on conflict (id) do nothing;
    else
      insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, buckets, created_by)
      select (r->>'id')::uuid, i.code, 'brew',
             -((r->>'buckets')::numeric * i.pack_g),
             d, (r->>'buckets')::numeric, uid
        from erp_items i
       where i.code = r->>'code' and (r->>'buckets')::numeric > 0
      on conflict (id) do nothing;
    end if;
    n := n + 1;
  end loop;

  if rev is not null and rev >= 0 then
    insert into erp_revenue (revenue_on, amount, updated_by, updated_at)
    values (d, rev, uid, now())
    on conflict (revenue_on)
      do update set amount = excluded.amount,
                    updated_by = excluded.updated_by,
                    updated_at = now();
  end if;

  return jsonb_build_object('ok', true, 'date', d, 'rows', n,
                            'items', (select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb)
                                      from erp_v_items v where v.is_tea));
end $$;

revoke all on function erp_log_brew(jsonb, date, numeric) from public, anon;
grant execute on function erp_log_brew(jsonb, date, numeric) to authenticated;

-- ---------------------------------------------------------------------

create or replace function erp_log_move(
  p_id   uuid,
  p_code text,
  p_kind text,          -- receive | use | waste
  p_qty  numeric,       -- 一律填正數，方向由 p_kind 決定
  p_note text default '',
  p_date date default null,
  p_unit_cost numeric default null,  -- 進貨才有意義；月結拿不到價格就留 null
  -- 只有「叫貨頁按到貨」才該把等貨中的單結掉。
  -- 臨時去別家買一斤應急，不該讓松霖那張單變成已到貨。
  p_close_order boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid   uuid := erp_require_staff();
  d     date := coalesce(p_date, erp_today());
  -- 進貨單價只有店長能給。店員帶了就當沒帶：
  -- 流水帳不存那個價、成本也不動，數量照常進庫存。
  ucost numeric := case when erp_is_manager() then p_unit_cost end;
  delta numeric;
  old_bal  numeric;
  old_cost numeric;
  ins   int;
begin
  if p_kind not in ('receive','use','waste') then
    raise exception '不支援的異動類型：%', p_kind using errcode = '22023';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception '數量必須大於 0' using errcode = '22023';
  end if;

  delta := case when p_kind = 'receive' then p_qty else -p_qty end;

  insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, note, unit_cost, created_by)
  values (p_id, p_code, p_kind, delta, d, coalesce(p_note,''), ucost, uid)
  on conflict (id) do nothing;
  get diagnostics ins = row_count;   -- 0 = 這筆已經寫過了（離線佇列重送）

  if p_kind = 'receive' then
    -- 這批是不是那張單的貨，只有前端知道，所以用旗標而不是自己猜
    if p_close_order then
      update erp_orders
         set status = 'received', received_on = d
       where item_code = p_code and status = 'pending';
    end if;

    -- 有報價才動成本，用移動平均：(舊庫存×舊成本 + 進貨量×進貨單價) / 總量
    -- 直接覆蓋成最新價會讓舊庫存的成本憑空跳動，毛利就不準了。
    -- ins = 0 代表這是重送，庫存沒有再增加，成本也不能再平均一次
    if ins = 1 and ucost is not null and ucost >= 0 then
      select coalesce(b.bal, 0), i.cost into old_bal, old_cost
        from erp_items i left join erp_v_balance b on b.code = i.code
       where i.code = p_code;
      -- old_bal 已含這筆進貨（view 是即時加總），所以要扣回去
      old_bal := greatest(old_bal - p_qty, 0);
      update erp_items
         set cost = case when old_bal + p_qty > 0
                         then round((old_bal * old_cost + p_qty * ucost) / (old_bal + p_qty), 4)
                         else ucost end,
             updated_at = now()
       where code = p_code;
    end if;
  end if;

  return jsonb_build_object('ok', true,
    'item', (select to_jsonb(v) from erp_v_items v where v.code = p_code));
end $$;

revoke all on function erp_log_move(uuid, text, text, numeric, text, date, numeric, boolean) from public, anon;
grant execute on function erp_log_move(uuid, text, text, numeric, text, date, numeric, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 驗證（貼完跑這段，三列都要 true；純 ASCII 不怕編碼）
-- select proname,
--        prosrc like '%erp_is_manager()%'                       as guarded,
--        prosrc like '%'||chr(19981)||chr(33021)||'%'          as zh_ok   -- 「不能」
--   from pg_proc
--  where proname in ('erp_log_brew','erp_log_move')
--  union all
-- select 'overloads', count(*) = 2, true
--   from pg_proc where proname in ('erp_log_brew','erp_log_move');
-- ---------------------------------------------------------------------
