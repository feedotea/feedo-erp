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
-- 2026-10-01 補：原本是 join erp_revenue，所以「整天完全沒有營收記錄」的
--   日子比不到 —— 正好是漏得最嚴重的那種。改成 left join，沒有那一列就
--   當 0 比，並多回一個 missing 旗標讓前端換句話說。公休日不會誤報，
--   因為那天連訂單都沒有。
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
             'revenue',       round(coalesce(r.amount, 0)),
             -- 整天沒有營收那一列：以前是 join，這種日子根本比不到，等於看不見
             'missing',       (r.revenue_on is null),
             'orders_amount', round(d.amt),
             'orders',        d.n,
             'diff',          round(d.amt - coalesce(r.amount, 0)),
             'pct',           round((d.amt - coalesce(r.amount, 0))
                                    / nullif(r.amount, 0) * 100, 1))
           order by d.sales_on desc)
      from (select sales_on, count(*) as n, sum(total) as amt
              from erp_pos_orders
             where sales_on >= erp_today() - p_days
             group by 1) d
      left join erp_revenue r on r.revenue_on = d.sales_on
     where abs(d.amt - coalesce(r.amount, 0))
           > greatest(100, coalesce(r.amount, 0) * p_tol)
  ), '[]'::jsonb);
end $$;

revoke all on function erp_revenue_gaps(int, numeric) from public, anon;
grant execute on function erp_revenue_gaps(int, numeric) to authenticated;

-- 驗證
-- select erp_revenue_gaps();          -- 9/30 補好之後應該回 []
-- select erp_revenue_gaps(120, 0.01); -- 放寬門檻可以看到那幾天的小差
-- 整天漏匯的測法：把某天的 erp_revenue 那列刪掉，應該會跳出 missing=true 的那筆
