-- =====================================================================
-- 25_cap_log.sql — 奶蓋「今天打了幾杯」登記
--
-- 為什麼要這張表：
-- 奶蓋是一鍋一鍋打的，打完沒賣完就整鍋倒。但系統一直只看得到兩端 ——
-- 賣掉的（POS 隔天才進來）和倒掉的（手動記損耗）—— 中間「到底打了多少」
-- 沒有人記，所以算不出浪費率，也沒辦法判斷該不該改打小鍋。
--
-- 刻意「只登記，不扣料」：
-- 扣料維持現狀（賣一杯扣一杯配方 + 倒掉記損耗）。要改成「打幾杯扣幾杯」
-- 才是正確的模型，但鮮奶茶奶蓋的鮮奶那一列是「基底 81.6 + 奶蓋 12.04」
-- 合併的，一列一個品項拆不開 —— 關掉它連基底都不扣，留著它奶蓋會扣兩次。
-- 那是動配方，不是加功能。先把杯數記起來，跑一個月拿到真實浪費率，
-- 再決定值不值得為了成本認列去動那 12 支配方。
--
-- 倒掉幾杯不另外存：損耗已經寫在 erp_stock_moves（五樣材料各一筆），
-- 用「配方裡用量最大的那一樣」除回去就是杯數，不會跟損耗清單對不起來。
--
-- 品名由前端傳（CAP_NAME），函式裡不寫中文字串 —— SQL Editor 貼上時
-- 少了 LC_ALL=en_US.UTF-8，中文會變亂碼而且不會報錯。
--
-- 部署：可重複執行。相依 01_schema（erp_stock_moves）、12_recipes（erp_recipes）。
-- =====================================================================

create table if not exists erp_cap_log (
  id         uuid primary key,                       -- 前端給，離線重送不會變兩筆
  made_on    date not null,
  cups       numeric(10,2) not null check (cups > 0),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists erp_cap_log_day on erp_cap_log(made_on);

alter table erp_cap_log enable row level security;
alter table erp_cap_log force  row level security;
revoke all on erp_cap_log from anon, authenticated;

-- ---------------------------------------------------------------------
-- 打了一鍋/半鍋就按一下。冪等：同一個 id 重送只會有一筆。
-- ---------------------------------------------------------------------
create or replace function erp_cap_log_add(p_id uuid, p_cups numeric, p_date date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := erp_require_staff();
  d   date := coalesce(p_date, erp_today());
begin
  if p_cups is null or p_cups <= 0 then
    raise exception 'cups must be > 0';
  end if;
  if d > erp_today() then
    raise exception 'cannot log a future date';
  end if;
  insert into erp_cap_log(id, made_on, cups, created_by)
  values (p_id, d, round(p_cups, 2), uid)
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 按錯了收回。店員只收得回自己按的，店長誰的都可以
-- （跟損耗、盤點同一個想法：事後看得到，不是事前擋住）。
-- ---------------------------------------------------------------------
create or replace function erp_cap_log_del(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := erp_require_staff();
  n   int;
begin
  delete from erp_cap_log
   where id = p_id
     and (created_by = uid or erp_is_manager());
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'not found, or not yours';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 某一天：打了幾杯、倒了幾杯、每一筆是誰按的。
-- 倒掉的杯數是從損耗回推的 —— 取配方裡用量最大的那一樣材料，
-- 它每杯固定幾克，把那天的損耗量除回去就是杯數。
-- ---------------------------------------------------------------------
create or replace function erp_cap_day(p_name text, p_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  d      date := coalesce(p_date, erp_today());
  made   numeric := 0;
  code0  text;
  q0     numeric;
  dumped numeric := 0;
begin
  perform erp_require_staff();

  select coalesce(sum(cups), 0) into made
    from erp_cap_log where made_on = d;

  select r.item_code, r.qty into code0, q0
    from erp_recipes r
   where r.pos_name = p_name
   order by r.qty desc
   limit 1;

  if code0 is not null and q0 is not null and q0 > 0 then
    select coalesce(sum(-m.qty_delta), 0) / q0 into dumped
      from erp_stock_moves m
     where m.kind = 'waste'
       and m.item_code = code0
       and m.occurred_on = d
       and m.note like p_name || '%';
  end if;

  return jsonb_build_object(
    'day',    d,
    'made',   round(made, 1),
    'dumped', round(dumped, 1),
    'rows',   coalesce((
       select jsonb_agg(jsonb_build_object(
                'id',   c.id,
                'cups', c.cups,
                'who',  coalesce(s.name, ''),
                'mine', (c.created_by = auth.uid()))
              order by c.created_at)
         from erp_cap_log c
         left join erp_staff s on s.user_id = c.created_by
        where c.made_on = d), '[]'::jsonb));
end $$;

revoke all    on function erp_cap_log_add(uuid, numeric, date) from public, anon;
revoke all    on function erp_cap_log_del(uuid)                from public, anon;
revoke all    on function erp_cap_day(text, date)              from public, anon;
grant execute on function erp_cap_log_add(uuid, numeric, date) to authenticated;
grant execute on function erp_cap_log_del(uuid)                to authenticated;
grant execute on function erp_cap_day(text, date)              to authenticated;
