-- =====================================================================
-- FEEDO ERP · 微碧 POS 匯入
--
-- 資料來源固定用「訂單列表.csv」。三個匯出檔只有它同時有
-- 日期 + 金額 + 品項 + 數量 + 選項：
--
--   訂單列表   ← 用這個
--   營運總表   品項分析是「一欄一個品項」的轉置版面，且無選項
--   交易列表   只有付款金額，沒有品項
--
-- 訂單項目欄長這樣（整格被引號包起來，逗號在引號內）：
--   "台東紅烏龍鮮奶茶奶蓋 x 2(1分甜,5分冰,封膜); 四杯袋"
--   → 品項間用 "; " 隔開；" x N" 是數量；括號內是選項
--
-- 選項裡的「環保杯」「封膜」之後要拿來精算包材：
-- 賣 100 杯但有 2 杯自帶環保杯 → 只扣 98 個紙杯。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 注意：這個檔案可以重複執行，不會動到既有資料。
-- （早期版本這裡有一段 drop table 的換版清理，資料進來之後那段
--   會把匯入紀錄整個刪掉，所以移除了。真的要重來請手動 delete。）
-- ---------------------------------------------------------------------

create table if not exists erp_pos_imports (
  id          uuid primary key,
  source      text not null default 'weiby',
  file_name   text,
  file_hash   text not null,
  date_from   date,
  date_to     date,
  order_count int  not null default 0,
  row_count   int  not null default 0,
  revenue     numeric(14,2) not null default 0,
  imported_by uuid not null references auth.users(id),
  imported_at timestamptz not null default now()
);

create unique index if not exists erp_pos_imports_hash_idx
  on erp_pos_imports (source, file_hash);

create table if not exists erp_pos_sales (
  id         uuid primary key default gen_random_uuid(),
  import_id  uuid not null references erp_pos_imports(id) on delete cascade,
  sales_on   date not null,
  order_no   text,                          -- 訂單編號，對得回微碧
  pos_name   text not null,                 -- 品項名（已去掉數量與括號）
  qty        numeric(12,2) not null default 1,
  options    text not null default '',      -- 3分甜,5分冰,封膜
  amount     numeric(14,2) not null default 0
);

create index if not exists erp_pos_sales_date_idx on erp_pos_sales (sales_on);
create index if not exists erp_pos_sales_name_idx on erp_pos_sales (pos_name);

/* 營運總表的「訂購品項分析」：微碧自己分好的類別、數量、小計。
   訂單列表只有整張單的總價拆不出單品營收，這裡才有。
   類別也是微碧給的，不用我猜「哪些算飲料」。

   注意：這段是「整份報表」的加總，不是逐日。報表通常就是一個
   營業日，所以用 date_to 當代表日；跨兩天的報表會全部算在後面
   那天。逐品項逐日的數量還是以 erp_pos_sales 為準。 */
create table if not exists erp_pos_categories (
  id         uuid primary key default gen_random_uuid(),
  import_id  uuid not null references erp_pos_imports(id) on delete cascade,
  sales_on   date not null,
  category   text not null,
  pos_name   text not null,
  qty        numeric(12,2) not null default 0,
  amount     numeric(14,2) not null default 0
);

create index if not exists erp_pos_cat_date_idx on erp_pos_categories (sales_on);
create index if not exists erp_pos_cat_cat_idx  on erp_pos_categories (category);

-- 微碧品項名 → ERP 品項。做配方扣料前必須先對應完。
create table if not exists erp_pos_item_map (
  pos_name   text primary key,
  item_code  text references erp_items(code) on update cascade,
  ignored    boolean not null default false,
  category   text,                     -- 從營運總表自動帶入，不用人工分類
  mapped_by  uuid references auth.users(id),
  mapped_at  timestamptz not null default now()
);

alter table erp_pos_item_map add column if not exists category text;

-- ---------------------------------------------------------------------
-- 匯入
--   p_days : [{"date":"2026-09-07","revenue":6663,"orders":69}]
--            營收用訂單總價加總，不是用品項金額 ——
--            訂單列表沒有逐品項的錢，只有整張訂單的總價。
--   p_rows : [{"date":"...","order_no":"910167","name":"台東紅烏龍",
--              "qty":2,"options":"1分甜,3分冰"}]
-- ---------------------------------------------------------------------
-- 多了 p_cats，簽章變了 —— create or replace 遇到不同簽章是多載不是取代
drop function if exists erp_pos_import(uuid, text, text, jsonb, jsonb, text);

create or replace function erp_pos_import(
  p_id        uuid,
  p_file_name text,
  p_file_hash text,
  p_days      jsonb,
  p_rows      jsonb,
  p_source    text default 'weiby',
  -- 營運總表的品項分析：[{"category":"奶蓋類","name":"...","qty":7,"amount":560}]
  p_cats      jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid    uuid := erp_require_manager();
  dates  date[];
  d      jsonb;
  n      int;
  dfrom  date;
  dto    date;
  v_existing uuid;
  v_import   uuid;
  tot    numeric := 0;
  ords   int := 0;
begin
  if p_days is null or jsonb_array_length(p_days) = 0 then
    raise exception '沒有可匯入的營業日' using errcode = '22023';
  end if;

  n := 0;   -- 只補分類時不會跑到明細那段，先給個值免得回傳 null
  select id into v_existing from erp_pos_imports
   where source = p_source and file_hash = p_file_hash;

  select array_agg((x->>'date')::date), min((x->>'date')::date), max((x->>'date')::date),
         sum((x->>'revenue')::numeric), sum(coalesce((x->>'orders')::int, 0))
    into dates, dfrom, dto, tot, ords
    from jsonb_array_elements(p_days) x;

  /* 同一份檔案匯過就不重複匯明細。
     但分類是後來加解析才拿得到的新資訊 —— 如果因為這樣就要把整批
     資料刪掉重匯，代價太大也太危險。所以重複的檔案照樣補分類。*/
  if v_existing is not null then
    v_import := v_existing;
  else
    v_import := p_id;
    insert into erp_pos_imports (id, source, file_name, file_hash,
                                 date_from, date_to, order_count, revenue, imported_by)
    values (p_id, p_source, p_file_name, p_file_hash, dfrom, dto, ords, tot, uid);
  end if;

 if v_existing is null then
  -- 同一天重匯（補了漏單再匯一次）→ 該日整批換掉，不疊加
  delete from erp_pos_sales where sales_on = any(dates);

  insert into erp_pos_sales (import_id, sales_on, order_no, pos_name, qty, options)
  select p_id, (r->>'date')::date, r->>'order_no', r->>'name',
         coalesce((r->>'qty')::numeric, 1), coalesce(r->>'options', '')
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r;

  get diagnostics n = row_count;
  update erp_pos_imports set row_count = n where id = v_import;

  /* 包材自動扣料。
     紙杯、封膜、袋子不需要配方 —— POS 的選項欄已經寫著答案：
       cup   飲料杯數扣掉自帶環保杯的（客人自己帶杯就不該扣）
       film  同紙杯（每杯都封膜；POS 那個「封膜」選項是特別註記用的，
             1086 杯只出現 2 次，不是每次都記）
       bag   賣出的兩杯袋／四杯袋
     糖、鮮奶、鮮奶油要真的配方，不在這裡處理。

     「哪些算飲料」跟報表用同一條推斷：有甜度或冰塊選項、或品名
     含茶/烏龍。等品項分類做完會換成正式分類。 */
  delete from erp_stock_moves
   where kind = 'use' and note = 'POS自動扣料' and occurred_on = any(dates);

  insert into erp_stock_moves (id, item_code, kind, qty_delta, occurred_on, note, created_by)
  -- 別名不能叫 d：函式裡已經有一個 jsonb 變數叫 d（跑營收迴圈用的），
  -- 撞名會讓 PostgreSQL 報 column reference "d" is ambiguous
  select gen_random_uuid(), i.code, 'use', -u.q, u.sd, 'POS自動扣料', uid
  from (
    select sd, role, sum(q) as q from (
      -- 紙杯和封膜：飲料杯數，扣掉自帶環保杯的
      select sales_on as sd, r.role, qty as q
        from erp_pos_sales, (values ('cup'),('film')) as r(role)
       where sales_on = any(dates)
         and (options ~ '甜|冰' or pos_name ~ '茶|烏龍')
         and options not like '%環保杯%'
      union all
      -- 袋子：賣出幾個就用掉幾個
      select sales_on, 'bag', qty
        from erp_pos_sales
       where sales_on = any(dates) and pos_name like '%杯袋%'
    ) z group by sd, role
  ) u
  join erp_items i on i.pos_role = u.role and i.active
  where u.q > 0;
 end if;   -- v_existing is null

  -- 營運總表的品項分析：類別、單品營收
  if p_cats is not null and jsonb_array_length(p_cats) > 0 then
    delete from erp_pos_categories where sales_on = dto;
    insert into erp_pos_categories (import_id, sales_on, category, pos_name, qty, amount)
    select v_import, dto, c->>'category', c->>'name',
           coalesce((c->>'qty')::numeric, 0), coalesce((c->>'amount')::numeric, 0)
    from jsonb_array_elements(p_cats) c;

    -- 分類自動帶進對應表，不用人工點 50 個品項
    insert into erp_pos_item_map (pos_name, category, mapped_by, mapped_at)
    select distinct c->>'name', c->>'category', uid, now()
    from jsonb_array_elements(p_cats) c
    on conflict (pos_name) do update set category = excluded.category, mapped_at = now();
  end if;

  -- 營收以 POS 為準，直接蓋掉手 key 的值
  for d in select * from jsonb_array_elements(p_days) where v_existing is null loop
    insert into erp_revenue (revenue_on, amount, note, updated_by, updated_at)
    values ((d->>'date')::date, (d->>'revenue')::numeric, '微碧匯入', uid, now())
    on conflict (revenue_on) do update set
      amount = excluded.amount, note = excluded.note,
      updated_by = excluded.updated_by, updated_at = now();
  end loop;

  return jsonb_build_object('ok', true,
    'reason', case when v_existing is null then 'imported' else 'categories_only' end,
    'rows', n, 'orders', ords, 'revenue', tot,
    'date_from', dfrom, 'date_to', dto, 'days', array_length(dates, 1));
end $$;

-- ---------------------------------------------------------------------
-- 匯入後的狀態：還沒對應的品項名、最近幾次匯入
-- ---------------------------------------------------------------------
create or replace function erp_pos_config(p_source text default 'weiby')
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform erp_require_manager();
  return jsonb_build_object(
    'unmapped', (select coalesce(jsonb_agg(x order by x.qty desc), '[]'::jsonb) from (
                   select s.pos_name as name, sum(s.qty) as qty
                   from erp_pos_sales s
                   left join erp_pos_item_map m on m.pos_name = s.pos_name
                   where m.pos_name is null
                   group by s.pos_name) x),
    'mapped',   (select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) from erp_pos_item_map m),
    'imports',  (select coalesce(jsonb_agg(to_jsonb(i) order by i.imported_at desc), '[]'::jsonb)
                 from (select * from erp_pos_imports
                       order by imported_at desc limit 20) i)
  );
end $$;

create or replace function erp_pos_map_item(
  p_pos_name text, p_item_code text default null, p_ignored boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := erp_require_manager();
begin
  insert into erp_pos_item_map (pos_name, item_code, ignored, mapped_by, mapped_at)
  values (p_pos_name, p_item_code, p_ignored, uid, now())
  on conflict (pos_name) do update set
    item_code = excluded.item_code, ignored = excluded.ignored,
    mapped_by = excluded.mapped_by, mapped_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 權限
-- ---------------------------------------------------------------------
alter table erp_pos_categories enable row level security;
alter table erp_pos_categories force row level security;
revoke all on erp_pos_categories from anon, authenticated;

alter table erp_pos_imports  enable row level security;
alter table erp_pos_sales    enable row level security;
alter table erp_pos_item_map enable row level security;

alter table erp_pos_imports  force row level security;
alter table erp_pos_sales    force row level security;
alter table erp_pos_item_map force row level security;

revoke all on erp_pos_imports, erp_pos_sales, erp_pos_item_map from anon, authenticated;

revoke all on function erp_pos_config(text)                       from public, anon;
revoke all on function erp_pos_import(uuid,text,text,jsonb,jsonb,text,jsonb) from public, anon;
revoke all on function erp_pos_map_item(text,text,boolean)        from public, anon;

grant execute on function erp_pos_config(text)                       to authenticated;
grant execute on function erp_pos_import(uuid,text,text,jsonb,jsonb,text,jsonb) to authenticated;
grant execute on function erp_pos_map_item(text,text,boolean)        to authenticated;
