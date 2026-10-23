-- Retailer USD; purchased sample, not enterprise or market totals.
-- Execute named blocks sequentially in a read-only model connection.

-- name: setup_line
CREATE TEMP TABLE analysis_line AS
SELECT t.basket_id,t.product_id,t.household_key,t.store_id,t.day,t.week_no,t.sales_value,
       p.display_group,p.department,p.commodity
FROM fact.transaction_line t JOIN dim.product p USING (product_id)
WHERE p.scope_status='include';

-- name: setup_windows
CREATE TEMP TABLE analysis_window AS
WITH last_week AS (
 SELECT max(week_no) w FROM dim.relative_day WHERE is_complete_observed_week
), bounds AS (
 SELECT 'all_observed' window_id,min(week_no) first_week,max(week_no) last_week,min(day) first_day,max(day) last_day
 FROM dim.relative_day
 UNION ALL
 SELECT 'previous_8w',w-15,w-8,min(day),max(day) FROM dim.relative_day CROSS JOIN last_week
 WHERE week_no BETWEEN w-15 AND w-8 GROUP BY w
 UNION ALL
 SELECT 'recent_8w',w-7,w,min(day),max(day) FROM dim.relative_day CROSS JOIN last_week
 WHERE week_no BETWEEN w-7 AND w GROUP BY w
)
SELECT *,last_day-first_day+1 observed_days FROM bounds;

-- name: windows
SELECT * FROM analysis_window ORDER BY first_day,last_day;

-- name: scope_overview
SELECT p.scope_status,count(*) detail_rows,count(DISTINCT t.basket_id) baskets,
 count(DISTINCT t.household_key) households,count(DISTINCT t.product_id) purchased_products,
 sum(t.sales_value) sales_value
FROM fact.transaction_line t JOIN dim.product p USING (product_id)
GROUP BY p.scope_status ORDER BY p.scope_status;

-- name: overview
SELECT w.window_id,count(*) detail_rows,count(DISTINCT basket_id) baskets,
 count(DISTINCT household_key) households,count(DISTINCT product_id) purchased_products,
 count(DISTINCT store_id) stores,sum(sales_value) sales_value,
 sum(sales_value)/nullif(count(DISTINCT basket_id),0) sales_per_basket,
 count(DISTINCT basket_id)*1.0/nullif(count(DISTINCT household_key),0) baskets_per_household,
 sum(sales_value)/nullif(count(DISTINCT household_key),0) sales_per_household
FROM analysis_line l JOIN analysis_window w ON l.day BETWEEN w.first_day AND w.last_day
GROUP BY w.window_id ORDER BY w.window_id;

-- name: weekly
WITH daily_frame AS (
 SELECT week_no,min(day) first_day,max(day) last_day,count(*) observed_days,
 bool_and(is_complete_observed_week) complete_week FROM dim.relative_day GROUP BY week_no
), totals AS (
 SELECT week_no,count(*) detail_rows,count(DISTINCT basket_id) baskets,
 count(DISTINCT household_key) households,sum(sales_value) sales_value
 FROM analysis_line GROUP BY week_no
), series AS (
 SELECT d.*,coalesce(t.detail_rows,0) detail_rows,coalesce(t.baskets,0) baskets,
 coalesce(t.households,0) households,coalesce(t.sales_value,0) sales_value
 FROM daily_frame d LEFT JOIN totals t USING (week_no)
), ratios AS (
 SELECT *,sales_value/nullif(baskets,0) sales_per_basket,
 sales_value/observed_days sales_per_observed_day,
 lag(sales_value) OVER (ORDER BY week_no) prior_sales,
 lag(complete_week) OVER (ORDER BY week_no) prior_complete_week,
 count(*) FILTER (WHERE complete_week) OVER (ORDER BY week_no ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) complete_weeks_in_4,
 avg(sales_value) OVER (ORDER BY week_no ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) rolling4_raw
 FROM series
)
SELECT * EXCLUDE (prior_sales,prior_complete_week,complete_weeks_in_4,rolling4_raw),
 CASE WHEN complete_week AND prior_complete_week AND prior_sales>0 THEN sales_value/prior_sales-1 END wow_change,
 CASE WHEN complete_weeks_in_4=4 THEN rolling4_raw END rolling4_complete_week_sales
FROM ratios ORDER BY week_no;

-- name: display_groups
WITH grouped AS (
 SELECT w.window_id,l.display_group,count(*) detail_rows,count(DISTINCT basket_id) baskets,
 count(DISTINCT household_key) households,count(DISTINCT product_id) purchased_products,
 sum(sales_value) sales_value
 FROM analysis_line l JOIN analysis_window w ON l.day BETWEEN w.first_day AND w.last_day
 GROUP BY w.window_id,l.display_group
), denominator AS (
 SELECT w.window_id,count(DISTINCT basket_id) baskets,count(DISTINCT household_key) households
 FROM analysis_line l JOIN analysis_window w ON l.day BETWEEN w.first_day AND w.last_day GROUP BY w.window_id
)
SELECT g.*,g.sales_value/sum(g.sales_value) OVER (PARTITION BY g.window_id) sales_share,
 g.households*1.0/d.households household_penetration,g.baskets*1.0/d.baskets basket_penetration,
 g.sales_value/nullif(g.baskets,0) category_sales_per_category_basket
FROM grouped g JOIN denominator d USING (window_id)
ORDER BY window_id,sales_value DESC,display_group;

-- name: setup_category_household
CREATE TEMP TABLE category_household AS
SELECT w.window_id,l.display_group,l.department,l.commodity,l.household_key,
 count(DISTINCT basket_id) baskets,sum(sales_value) sales_value
FROM analysis_line l JOIN analysis_window w ON l.day BETWEEN w.first_day AND w.last_day
GROUP BY w.window_id,l.display_group,l.department,l.commodity,l.household_key;

-- name: categories
WITH totals AS (
 SELECT window_id,display_group,department,commodity,count(*) households,
 sum(baskets) baskets,sum(sales_value) sales_value,count(*) FILTER (WHERE baskets>=2) multi_basket_households
 FROM category_household GROUP BY window_id,display_group,department,commodity
), denominator AS (
 SELECT w.window_id,count(DISTINCT basket_id) baskets,count(DISTINCT household_key) households
 FROM analysis_line l JOIN analysis_window w ON l.day BETWEEN w.first_day AND w.last_day GROUP BY w.window_id
), metrics AS (
 SELECT t.*,t.sales_value/sum(t.sales_value) OVER (PARTITION BY t.window_id) sales_share,
 t.households*1.0/d.households household_penetration,t.baskets*1.0/d.baskets basket_penetration,
 t.baskets*1.0/nullif(t.households,0) baskets_per_buyer,t.sales_value/nullif(t.baskets,0) sales_per_category_basket,
 t.multi_basket_households*1.0/nullif(t.households,0) multi_basket_buyer_share
 FROM totals t JOIN denominator d USING (window_id)
)
SELECT *,row_number() OVER (PARTITION BY window_id ORDER BY sales_value DESC,display_group,department,commodity) sales_rank,
 sum(sales_share) OVER (PARTITION BY window_id ORDER BY sales_value DESC,display_group,department,commodity
 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) cumulative_sales_share
FROM metrics ORDER BY window_id,sales_rank;

-- name: category_change
WITH period AS (
 SELECT window_id,display_group,department,commodity,count(*) households,
 sum(baskets) baskets,sum(sales_value) sales_value
 FROM category_household WHERE window_id IN ('previous_8w','recent_8w')
 GROUP BY window_id,display_group,department,commodity
), combined AS (
 SELECT display_group,department,commodity,
 coalesce(max(sales_value) FILTER (WHERE window_id='previous_8w'),0) previous_sales,
 coalesce(max(sales_value) FILTER (WHERE window_id='recent_8w'),0) recent_sales,
 coalesce(max(households) FILTER (WHERE window_id='previous_8w'),0) previous_buyers,
 coalesce(max(households) FILTER (WHERE window_id='recent_8w'),0) recent_buyers,
 coalesce(max(baskets) FILTER (WHERE window_id='previous_8w'),0) previous_baskets,
 coalesce(max(baskets) FILTER (WHERE window_id='recent_8w'),0) recent_baskets
 FROM period GROUP BY display_group,department,commodity
)
SELECT *,recent_sales-previous_sales sales_delta,
 CASE WHEN previous_sales>0 THEN recent_sales/previous_sales-1 END sales_change,
 previous_baskets*1.0/nullif(previous_buyers,0) previous_baskets_per_buyer,
 recent_baskets*1.0/nullif(recent_buyers,0) recent_baskets_per_buyer,
 previous_sales/nullif(previous_baskets,0) previous_sales_per_basket,
 recent_sales/nullif(recent_baskets,0) recent_sales_per_basket
FROM combined ORDER BY sales_delta DESC,display_group,department,commodity;

-- name: common_buyers_sensitivity
WITH active AS (
 SELECT DISTINCT w.window_id,l.household_key
 FROM analysis_line l JOIN analysis_window w ON l.day BETWEEN w.first_day AND w.last_day
 WHERE w.window_id IN ('previous_8w','recent_8w')
), common AS (
 SELECT household_key FROM active GROUP BY household_key HAVING count(*)=2
)
SELECT w.window_id,count(DISTINCT l.household_key) households,count(DISTINCT basket_id) baskets,
 sum(sales_value) sales_value,sum(sales_value)/count(DISTINCT basket_id) sales_per_basket,
 count(DISTINCT basket_id)*1.0/count(DISTINCT l.household_key) baskets_per_household
FROM analysis_line l JOIN common c USING (household_key)
JOIN analysis_window w ON l.day BETWEEN w.first_day AND w.last_day
WHERE w.window_id IN ('previous_8w','recent_8w')
GROUP BY w.window_id ORDER BY w.window_id;
