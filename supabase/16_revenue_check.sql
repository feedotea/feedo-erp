-- =====================================================================
-- 16_revenue_check.sql — 營收與訂單明細的每日對帳提醒
--
-- 為什麼要這一支
--   微碧的報表是跨夜區間（例如 17:47 – 隔天 18:24），所以同一個營業日
--   會被切在兩封信裡。先到的那封只帶當天的尾巴；如果後面那封匯入失敗，
--   那天的「營收」就會停在一個很小的數字，而訂單明細卻是完整的
--   —— 2026-09 發生過一次。
--
--   對帳本身很簡單：同一天的 erp_revenue.amount 應該接近
--   erp_pos_orders 的 total 總和。差太多就是有一邊沒進來。
--
-- 門檻
--   差額同時超過「100 元」與「5%」才算。營運總表與訂單明細本來就會有
--   小差（招待、退款的算法不同），實測落在 2% 以內，不該報警。
--
-- 權限：只有店長／老闆看得到（金額）。部署順序：15 之後。可重複執行。
-- =====================================================================

create or replace function erp_revenue_gaps(
  p_days int default 60,
  p_tol  numeric default 0.05
)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform erp_require_manager();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'day',           d.sales_on,
             'revenue',       round(r.amount),
             'orders_amount', round(d.amt),
             'orders',        d.n,
             'diff',          round(d.amt - r.amount),
             'pct',           round((d.amt - r.amount) / nullif(r.amount, 0) * 100, 1))
           order by d.sales_on desc)
      from (select sales_on, count(*) as n, sum(total) as amt
              from erp_pos_orders
             where sales_on >= erp_today() - p_days
             group by 1) d
      join erp_revenue r on r.revenue_on = d.sales_on
     where abs(d.amt - r.amount) > greatest(100, r.amount * p_tol)
  ), '[]'::jsonb);
end $$;

revoke all on function erp_revenue_gaps(int, numeric) from public, anon;
grant execute on function erp_revenue_gaps(int, numeric) to authenticated;

-- 驗證
-- select erp_revenue_gaps();          -- 修好 9/13 之後應該回 []
-- select erp_revenue_gaps(120, 0.01); -- 放寬門檻可以看到那幾天的小差
