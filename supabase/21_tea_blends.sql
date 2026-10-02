-- =====================================================================
-- 21_tea_blends.sql — 拼茶：煮一桶自動扣兩支原料茶
--
-- 為什麼要這一支
--   煮茶原本是「一桶 ＝ 一包那支茶」，一桶只能扣一個品項。但店裡有三種
--   茶桶是拼的，一桶 100g 裡混了兩種茶：
--     紅烏龍（純茶）      迎香 50 ＋ 金萱 50   （450/400 價格各半）
--     台東紅烏龍鮮奶茶    迎香 75 ＋ 阿薩姆 25 （3:1）
--     小葉鮮奶紅茶        小葉紅 75 ＋ 阿薩姆 25（3:1）
--   所以迎香紅烏龍從頭到尾沒被扣過（它根本不在煮茶頁上），阿薩姆也少扣。
--
-- 做法
--   品項上掛一張「一桶用哪些原料、各幾克」的表，erp_log_brew 看到拼茶就
--   改成扣原料。**店員操作完全不變**，照樣只按桶數。
--
-- 冪等：每筆原料的 move id 由「前端給的 id ＋ 原料代號」算出來，
--   離線佇列重送不會變成兩筆。桶數只記在第一筆，畫面不會算成兩倍。
--
-- 部署：19/20 之後。可重複執行。2026-10-02 已在正式庫執行。
-- =====================================================================

begin;

create table if not exists erp_tea_blends (
  blend_code text not null references erp_items(code) on update cascade,
  part_code  text not null references erp_items(code) on update cascade,
  grams      numeric(10,3) not null check (grams > 0),   -- 一桶用幾克
  primary key (blend_code, part_code)
);

alter table erp_tea_blends enable row level security;
drop policy if exists erp_tea_blends_read on erp_tea_blends;
create policy erp_tea_blends_read on erp_tea_blends for select to authenticated using (erp_is_staff());
revoke all on erp_tea_blends from anon;

-- 1) TEA-01 其實是金萱（成本 400 元/斤），改名當原料，不再單獨煮
update erp_items set name = '金萱紅烏龍', is_tea = false, updated_at = now() where code = 'TEA-01';

-- 2) 三支拼茶放進煮茶頁（一桶 100g；成本是兩支原料按比例的加權，只用來顯示）
insert into erp_items (code, name, cat, unit, cost, safe_qty, lead_days, cover_days,
                       is_tea, pack_g, active, updated_at)
values ('TEA-21', '紅烏龍（拼）',           '茶葉', 'g', 0.708334, 0, 3, 14, true, 100, true, now()),
       ('TEA-22', '台東紅烏龍鮮奶茶（拼）', '茶葉', 'g', 0.629167, 0, 3, 14, true, 100, true, now()),
       ('TEA-23', '小葉鮮奶紅茶（拼）',     '茶葉', 'g', 0.566667, 0, 3, 14, true, 100, true, now())
on conflict (code) do update set name=excluded.name, is_tea=true, pack_g=100,
       cost=excluded.cost, active=true, updated_at=now();

-- 3) 一桶的組成
insert into erp_tea_blends (blend_code, part_code, grams) values
  ('TEA-21','TEA-11',50), ('TEA-21','TEA-01',50),   -- 迎香 ＋ 金萱
  ('TEA-22','TEA-11',75), ('TEA-22','TEA-06',25),   -- 迎香 ＋ 阿薩姆
  ('TEA-23','TEA-03',75), ('TEA-23','TEA-06',25)    -- 小葉紅（機採紅茶）＋ 阿薩姆
on conflict (blend_code, part_code) do update set grams = excluded.grams;

-- 阿薩姆一包 300g，但一桶也是煮 100g。煮茶原本扣的是 pack_g（一包），會多扣三倍，
-- 所以給它一條「自己拼自己 100g」的規則，走跟拼茶同一條路。
-- 其他茶一包剛好就是一桶 100g，不用特別處理。
insert into erp_tea_blends (blend_code, part_code, grams) values ('TEA-06','TEA-06',100)
on conflict (blend_code, part_code) do update set grams = excluded.grams;

-- 4) 煮茶：拼茶改扣原料
create or replace function erp_log_brew(
  p_rows    jsonb,
  p_date    date    default null,
  p_revenue numeric default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := erp_require_staff();
  d    date := coalesce(p_date, erp_today());
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

  if p_revenue is not null and p_revenue >= 0 then
    insert into erp_revenue (revenue_on, amount, updated_by, updated_at)
    values (d, p_revenue, uid, now())
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

commit;

-- 驗證
-- select * from erp_tea_blends order by blend_code, part_code;
-- select code, name, is_tea, pack_g, cost from erp_items where cat='茶葉' order by code;
