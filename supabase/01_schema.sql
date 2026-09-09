-- =====================================================================
-- FEEDO ERP · Supabase schema
-- 專案：gezzdwwqxysesxoqhabe（與 feedo-claim 共用）
-- 命名一律 erp_ 前綴，避免和 claim 的表撞名
--
-- 設計三原則：
--   1. 庫存是「帳」不是「數字」：所有異動 append 到 erp_stock_moves，
--      餘額 = sum(qty_delta)。永遠可回溯，盤點也是一筆調整而非覆蓋。
--   2. 每筆寫入帶 client 產生的 uuid：斷線重試不會變成兩筆。
--   3. 前端只能呼叫 RPC，base table 全部 RLS deny-all。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 共用工具
-- ---------------------------------------------------------------------

-- Supabase 的 now() 是 UTC。台灣早上 8 點前記帳會被算成前一天，
-- 所有「今天」一律走這個函式。
create or replace function erp_today() returns date
language sql stable as $$
  select (now() at time zone 'Asia/Taipei')::date;
$$;

-- 員工名冊：只有列在這裡的 auth 使用者能操作 ERP
create table if not exists erp_staff (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  name      text not null,
  role      text not null default 'staff'
            check (role in ('staff','manager','owner')),
  active    boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function erp_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from erp_staff
    where user_id = auth.uid() and active
  );
$$;

create or replace function erp_is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from erp_staff
    where user_id = auth.uid() and active and role in ('manager','owner')
  );
$$;

-- 每個寫入 RPC 開頭都呼叫這個
create or replace function erp_require_staff() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception '尚未登入' using errcode = '28000';
  end if;
  if not erp_is_staff() then
    raise exception '此帳號沒有 ERP 權限' using errcode = '42501';
  end if;
  return uid;
end $$;

-- ---------------------------------------------------------------------
-- 1. 主檔
-- ---------------------------------------------------------------------

create table if not exists erp_suppliers (
  name        text primary key,
  contact     text,
  note        text,
  -- 月結：帳單日 / 付款條件，之後做應付帳款會用到
  terms_days  int,
  active      boolean not null default true
);

create table if not exists erp_items (
  code        text primary key,
  name        text not null,
  cat         text not null,                       -- 茶葉 / 包材 / 糖類 …
  unit        text not null,                       -- g / 個 / 箱 / 組
  safe_qty    numeric(14,3) not null default 0,    -- 安全庫存（原單位）
  cost        numeric(12,4) not null default 0,    -- 單位成本
  supplier    text references erp_suppliers(name) on update cascade,
  is_tea      boolean not null default false,
  -- 茶葉一桶幾公克。原本前端寫死 PACK_G=100，移到資料庫才改得動
  pack_g      numeric(10,2) not null default 100,
  -- 手動預估日用量。有足夠實際紀錄後會被真實數據取代，見 erp_v_items
  avg_per_day_manual numeric(12,3) not null default 0,
  note        text not null default '',
  active      boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists erp_items_active_idx on erp_items (active, cat, sort_order);

-- ---------------------------------------------------------------------
-- 2. 庫存異動帳（唯一的庫存真相來源）
-- ---------------------------------------------------------------------

create table if not exists erp_stock_moves (
  id          uuid primary key,                    -- 前端產生，用來擋重送
  item_code   text not null references erp_items(code) on update cascade,
  kind        text not null check (kind in (
                'brew',       -- 煮茶（負）
                'use',        -- 一般用量（負）
                'receive',    -- 進貨（正）
                'waste',      -- 報廢（負）
                'stocktake'   -- 盤點調整（正負皆可）
              )),
  qty_delta   numeric(14,3) not null,              -- 帶正負號，一律用 item 的原單位
  occurred_on date not null,                       -- 可補登，不等於 created_at
  note        text not null default '',
  -- 煮茶專用：記下當時桶數，日後對帳看得懂
  buckets     numeric(8,2),
  -- 進貨當下的單價。erp_items.cost 是「現在的成本」，會被覆蓋；
  -- 這裡留的是「當時付了多少」。不記下來，成本歷史永遠補不回來。
  unit_cost   numeric(12,4),
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now()
);

alter table erp_stock_moves add column if not exists unit_cost numeric(12,4);

create index if not exists erp_moves_item_date_idx on erp_stock_moves (item_code, occurred_on desc);
create index if not exists erp_moves_date_idx      on erp_stock_moves (occurred_on desc);

-- ---------------------------------------------------------------------
-- 3. 叫貨
-- ---------------------------------------------------------------------

create table if not exists erp_orders (
  id          uuid primary key,
  item_code   text not null references erp_items(code) on update cascade,
  supplier    text,
  qty         numeric(14,3) not null,
  unit        text not null,                       -- 茶葉是「斤」，和 item.unit 可能不同
  status      text not null default 'pending'
              check (status in ('pending','received','cancelled')),
  ordered_on  date not null,
  received_on date,
  note        text not null default '',
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now()
);

-- 同一品項同時只會有一張未到貨的單
create unique index if not exists erp_orders_one_pending_idx
  on erp_orders (item_code) where status = 'pending';

-- ---------------------------------------------------------------------
-- 4. 帳務
-- ---------------------------------------------------------------------

create table if not exists erp_expenses (
  id          uuid primary key,
  spent_on    date not null,
  cat         text not null,                       -- 房租 / 水電 / 廠商貨款 …
  amount      numeric(14,2) not null check (amount > 0),
  payee       text not null default '—',
  method      text not null default '轉帳',
  note        text not null default '',
  paid        boolean not null default true,
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now()
);

create index if not exists erp_expenses_date_idx on erp_expenses (spent_on desc);

create table if not exists erp_revenue (
  revenue_on  date primary key,                    -- 一天一筆，重記就覆蓋
  amount      numeric(14,2) not null check (amount >= 0),
  note        text not null default '',
  updated_by  uuid not null references auth.users(id),
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 5. 衍生檢視
--
-- 先 drop 再建：CREATE OR REPLACE VIEW 只能在欄位「最後面」加欄位，
-- 不能改既有欄位的順序或名稱。erp_v_items 這次在中間插了
-- avg_per_day_manual，直接 replace 會噴
-- "cannot change name of view column"。
-- 相依順序：erp_v_items 依賴另外兩個，所以它要先 drop。
-- ---------------------------------------------------------------------
drop view if exists erp_v_items;
drop view if exists erp_v_usage;
drop view if exists erp_v_balance;

-- 目前餘額 = 異動加總
create or replace view erp_v_balance as
select i.code,
       coalesce(sum(m.qty_delta), 0)::numeric(14,3) as bal
from erp_items i
left join erp_stock_moves m on m.item_code = i.code
group by i.code;

-- 實際日用量：近 28 天的 brew + use（不含報廢，報廢不該拉高預測）
create or replace view erp_v_usage as
select i.code,
       coalesce(sum(-m.qty_delta), 0) / 28.0 as avg_actual,
       count(distinct m.occurred_on)          as days_with_data
from erp_items i
left join erp_stock_moves m
       on m.item_code = i.code
      and m.kind in ('brew','use')
      and m.qty_delta < 0
      and m.occurred_on > erp_today() - 28
group by i.code;

-- 前端要的完整品項狀態
create or replace view erp_v_items as
select
  i.code, i.name, i.cat, i.unit, i.safe_qty, i.cost, i.supplier,
  i.is_tea, i.pack_g, i.note, i.sort_order, i.avg_per_day_manual,
  b.bal,
  -- 累積 14 天以上實際資料才敢用真實數據，否則沿用手填值
  case when u.days_with_data >= 14 and u.avg_actual > 0
       then round(u.avg_actual, 3)
       else i.avg_per_day_manual
  end as avg_per_day,
  (u.days_with_data >= 14 and u.avg_actual > 0) as avg_is_actual,
  exists (select 1 from erp_orders o
          where o.item_code = i.code and o.status = 'pending') as on_order
from erp_items i
join erp_v_balance b using (code)
join erp_v_usage   u using (code)
where i.active;
