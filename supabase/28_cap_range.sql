-- =====================================================================
-- 28_cap_range.sql — 奶蓋打製紀錄（一段期間）
--
-- erp_cap_day 一次只回一天，是給煮茶頁當天用的。
-- 煮茶紀錄要看「這段期間每天打了幾杯、倒了幾杯」，所以開一支範圍版。
--
-- 倒掉的杯數一樣從損耗回推：取奶蓋配方裡用量最大的那一樣材料，
-- 它每杯固定幾克，把那天的損耗量除回去就是杯數。
-- 配方改了也會自己跟著對，不會跟損耗清單對不起來。
--
-- 品名由前端傳（CAP_NAME），函式裡不寫中文字串。
-- 部署：可重複執行。相依 25_cap_log（erp_cap_log）。
-- =====================================================================

create or replace function erp_cap_range(p_name text, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  code0 text;
  q0    numeric;
begin
  perform erp_require_staff();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'bad date range';
  end if;
  if p_to - p_from > 400 then
    raise exception 'range too long';
  end if;

  select r.item_code, r.qty into code0, q0
    from erp_recipes r
   where r.pos_name = p_name
   order by r.qty desc
   limit 1;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'day',    d,
             'made',   round(made, 1),
             'dumped', round(dumped, 1))
           order by d desc)
      from (
        select g.d::date as d,
               coalesce((select sum(c.cups) from erp_cap_log c where c.made_on = g.d::date), 0) as made,
               case when code0 is null or q0 is null or q0 <= 0 then 0 else
                 coalesce((select sum(-m.qty_delta) from erp_stock_moves m
                            where m.kind = 'waste' and m.item_code = code0
                              and m.occurred_on = g.d::date
                              and m.note like p_name || '%'), 0) / q0
               end as dumped
          from generate_series(p_from, p_to, interval '1 day') g(d)
      ) t
     where made > 0 or dumped > 0
  ), '[]'::jsonb);
end $$;

revoke all    on function erp_cap_range(text, date, date) from public, anon;
grant execute on function erp_cap_range(text, date, date) to authenticated;
