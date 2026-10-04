-- =====================================================================
-- 29_month_series.sql — 各月損益（一次拿好幾個月）
--
-- erp_month_report 一次只回一個月，報表頁要一個月一個月用 ◀▶ 翻。
-- 老闆：「應該要有一個地方可以看月報表」—— 要的是把每個月排在一起看趨勢，
-- 不是翻頁。所以開一支一次回 N 個月的。
--
-- 只回損益表要的四個數：營收、物料成本、營業費用、有幾天營收。
-- 毛利和淨利由前端算（算式跟報表頁同一套，不要兩邊各算各的）。
--
-- ⚠ 營業費用**排除「廠商貨款」** —— 那是現金流不是成本，
--   真正的料錢是耗用的時候從庫存算的（就是這裡的 cogs）。
--   報表頁的 opex 也是這樣排除的，兩邊要一致。
--
-- 部署：可重複執行。
-- =====================================================================

create or replace function erp_month_series(p_months int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  n int := greatest(1, least(coalesce(p_months, 12), 36));
  m0 date := (date_trunc('month', erp_today()) - make_interval(months => n - 1))::date;
begin
  perform erp_require_manager();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'month',   to_char(g.m, 'YYYY-MM'),
             'revenue', coalesce(r.amt, 0),
             'days',    coalesce(r.days, 0),
             'cogs',    coalesce(c.amt, 0),
             'opex',    coalesce(e.amt, 0))
           order by g.m desc)
      from generate_series(m0, date_trunc('month', erp_today())::date, interval '1 month') g(m)
      left join lateral (
        select sum(amount) amt, count(*) days from erp_revenue
         where revenue_on >= g.m and revenue_on < (g.m + interval '1 month')
      ) r on true
      left join lateral (
        select sum(-sm.qty_delta * i.cost) amt
          from erp_stock_moves sm join erp_items i on i.code = sm.item_code
         where sm.kind in ('brew','use') and sm.qty_delta < 0
           and sm.occurred_on >= g.m and sm.occurred_on < (g.m + interval '1 month')
      ) c on true
      left join lateral (
        select sum(amount) amt from erp_expenses
         where spent_on >= g.m and spent_on < (g.m + interval '1 month')
           -- 廠商貨款是現金流，不是成本
           and cat <> chr(24288)||chr(21830)||chr(36008)||chr(27454)
      ) e on true
  ), '[]'::jsonb);
end $$;

revoke all    on function erp_month_series(int) from public, anon;
grant execute on function erp_month_series(int) to authenticated;
