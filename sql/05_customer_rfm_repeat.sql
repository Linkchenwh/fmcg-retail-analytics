-- One customer is one household. Reference day = last complete day + 1.
-- Window and threshold definitions: docs/metrics.md.

-- name: setup_windows
CREATE TEMP TABLE analysis_windows AS
WITH ending AS (
 SELECT max(week_no) w FROM dim.relative_day WHERE is_complete_observed_week
), bounds AS (
 SELECT 'rfm_13w' window_id,w-12 first_week,w last_week,true use_rfm,true use_promotion
 FROM ending UNION ALL
 SELECT 'rfm_8w',w-7,w,true,false FROM ending UNION ALL
 SELECT 'all_observed',min(week_no),max(week_no),false,true FROM dim.relative_day
)
SELECT b.*,min(d.day) first_day,max(d.day) last_day,max(d.day)+1 reference_day,
 count(*) observed_days FROM bounds b JOIN dim.relative_day d
 ON d.week_no BETWEEN b.first_week AND b.last_week
GROUP BY ALL;

-- name: windows
SELECT * FROM analysis_windows ORDER BY window_id;

-- name: setup_lines
CREATE TEMP TABLE main_line AS
SELECT t.basket_id,t.product_id,t.household_key,t.store_id,t.day,t.week_no,
 t.sales_value,t.retail_disc,t.coupon_disc,t.coupon_match_disc,p.display_group,
 c.product_id IS NOT NULL has_promotion_context,c.display_present,c.mailer_present
FROM fact.transaction_line t JOIN dim.product p USING(product_id)
LEFT JOIN fact.promotion_context c USING(product_id,store_id,week_no)
WHERE p.scope_status='include';

-- name: setup_baskets
CREATE TEMP TABLE main_basket AS
SELECT basket_id,min(household_key) household_key,min(day) AS day,
 sum(sales_value) sales_value,
 bool_or(retail_disc<0) has_loyalty_discount,
 bool_or(coupon_disc<0 OR coupon_match_disc<0) has_coupon_discount,
 bool_or(retail_disc>0 OR coupon_disc>0 OR coupon_match_disc>0) positive_exception,
 sum(CASE WHEN retail_disc<0 THEN -retail_disc ELSE 0 END) loyalty_abs,
 sum(CASE WHEN coupon_disc<0 THEN -coupon_disc ELSE 0 END) coupon_abs,
 sum(CASE WHEN coupon_match_disc<0 THEN -coupon_match_disc ELSE 0 END) match_abs,
 sum(CASE WHEN retail_disc<0 OR coupon_disc<0 OR coupon_match_disc<0 THEN sales_value ELSE 0 END) discounted_line_sales
FROM main_line GROUP BY basket_id;

-- name: setup_window_baskets
CREATE TEMP TABLE window_basket AS
SELECT w.window_id,b.* FROM analysis_windows w JOIN main_basket b
 ON b.day BETWEEN w.first_day AND w.last_day;

-- name: setup_rfm_base
CREATE TEMP TABLE rfm_base AS
WITH bought AS (
 SELECT b.window_id,b.household_key,max(b.day) last_purchase_day,
 count(*) frequency,sum(b.sales_value) monetary
 FROM window_basket b JOIN analysis_windows w USING(window_id)
 WHERE w.use_rfm GROUP BY b.window_id,b.household_key
)
SELECT w.window_id,h.household_key,h.has_demographics,
 h.first_observed_day<=w.first_day observed_by_window_start,
 b.last_purchase_day,w.reference_day-b.last_purchase_day recency,
 coalesce(b.frequency,0) frequency,coalesce(b.monetary,0) monetary
FROM dim.household h CROSS JOIN analysis_windows w
LEFT JOIN bought b ON b.window_id=w.window_id AND b.household_key=h.household_key
WHERE w.use_rfm;

-- name: setup_cutoffs
CREATE TEMP TABLE rfm_cutoffs AS
SELECT window_id,quantile_disc(recency,[0.2,0.4,0.6,0.8]) r_cuts,
 quantile_disc(frequency,[0.2,0.4,0.6,0.8]) f_cuts,
 quantile_disc(monetary,[0.2,0.4,0.6,0.8]) m_cuts
FROM rfm_base WHERE frequency>0 GROUP BY window_id;

-- name: cutoffs
SELECT window_id,'R_days' metric,unnest([0.2,0.4,0.6,0.8]) percentile,unnest(r_cuts) cutoff
FROM rfm_cutoffs UNION ALL
SELECT window_id,'F_baskets',unnest([0.2,0.4,0.6,0.8]),unnest(f_cuts) FROM rfm_cutoffs UNION ALL
SELECT window_id,'M_usd',unnest([0.2,0.4,0.6,0.8]),unnest(m_cuts) FROM rfm_cutoffs
ORDER BY window_id,metric,percentile;

-- name: setup_rfm
CREATE TEMP TABLE rfm AS
WITH scored AS (
 SELECT b.*,
 CASE WHEN frequency=0 THEN NULL WHEN recency<=r_cuts[1] THEN 5 WHEN recency<=r_cuts[2] THEN 4
 WHEN recency<=r_cuts[3] THEN 3 WHEN recency<=r_cuts[4] THEN 2 ELSE 1 END r_score,
 CASE WHEN frequency=0 THEN NULL WHEN frequency<=f_cuts[1] THEN 1 WHEN frequency<=f_cuts[2] THEN 2
 WHEN frequency<=f_cuts[3] THEN 3 WHEN frequency<=f_cuts[4] THEN 4 ELSE 5 END f_score,
 CASE WHEN frequency=0 THEN NULL WHEN monetary<=m_cuts[1] THEN 1 WHEN monetary<=m_cuts[2] THEN 2
 WHEN monetary<=m_cuts[3] THEN 3 WHEN monetary<=m_cuts[4] THEN 4 ELSE 5 END m_score
 FROM rfm_base b JOIN rfm_cutoffs c USING(window_id)
)
SELECT *,CASE WHEN frequency=0 THEN 'window_no_purchase'
 WHEN r_score>=4 AND f_score>=4 AND m_score>=4 THEN 'recent_high_frequency_high_monetary'
 WHEN r_score>=4 AND f_score>=3 THEN 'recent_regular'
 WHEN r_score>=4 THEN 'recent_low_frequency'
 WHEN r_score<=2 AND (f_score>=4 OR m_score>=4) THEN 'less_recent_high_frequency_or_monetary'
 WHEN r_score<=2 THEN 'less_recent' ELSE 'middle_recency' END segment
FROM scored;

-- name: rfm_households
SELECT * FROM rfm ORDER BY window_id,household_key;

-- name: rfm_segments
SELECT window_id,segment,count(*) households,
 count(*)*1.0/sum(count(*)) OVER(PARTITION BY window_id) household_share,
 sum(frequency) baskets,sum(monetary) sales_value,
 sum(monetary)/nullif(sum(sum(monetary)) OVER(PARTITION BY window_id),0) sales_share,
 avg(recency) mean_recency,avg(frequency) mean_frequency,avg(monetary) mean_monetary,
 count(*) FILTER(WHERE has_demographics) households_with_demographics,
 count(*) FILTER(WHERE NOT observed_by_window_start) first_observed_after_window_start
FROM rfm GROUP BY window_id,segment ORDER BY window_id,sales_value DESC,segment;

-- name: rfm_window_sensitivity
SELECT a.segment segment_13w,b.segment segment_8w,count(*) households
FROM rfm a JOIN rfm b USING(household_key)
WHERE a.window_id='rfm_13w' AND b.window_id='rfm_8w'
GROUP BY a.segment,b.segment ORDER BY a.segment,b.segment;

-- name: setup_purchase_days
CREATE TEMP TABLE purchase_day AS
SELECT DISTINCT b.window_id,b.household_key,b.day
FROM window_basket b JOIN analysis_windows w USING(window_id) WHERE w.use_rfm;

-- name: setup_intervals
CREATE TEMP TABLE purchase_sequence AS
SELECT *,lead(day) OVER(PARTITION BY window_id,household_key ORDER BY day) next_day,
 row_number() OVER(PARTITION BY window_id,household_key ORDER BY day) ordinal
FROM purchase_day;

-- name: setup_repeat
CREATE TEMP TABLE repeat_household AS
WITH days AS (
 SELECT window_id,household_key,count(*) purchase_days FROM purchase_day GROUP BY window_id,household_key
)
SELECT s.window_id,s.household_key,s.day index_day,s.next_day,s.next_day-s.day days_to_next,
 d.purchase_days,r.frequency baskets,s.day<=w.last_day-30 eligible_30d,
 CASE WHEN s.day<=w.last_day-30 THEN coalesce(s.next_day<=s.day+30,false) END repeat_30d
FROM purchase_sequence s JOIN days d USING(window_id,household_key)
JOIN rfm r USING(window_id,household_key) JOIN analysis_windows w USING(window_id)
WHERE s.ordinal=1;

-- name: repeat_households
SELECT * FROM repeat_household ORDER BY window_id,household_key;

-- name: repeat_summary
SELECT window_id,count(*) buyers,count(*) FILTER(WHERE baskets>=2) multi_basket_buyers,
 count(*) FILTER(WHERE purchase_days>=2) multi_day_buyers,
 count(*) FILTER(WHERE eligible_30d) eligible_30d_buyers,
 count(*) FILTER(WHERE NOT eligible_30d) insufficient_followup_buyers,
 count(*) FILTER(WHERE repeat_30d) repeat_30d_buyers,
 count(*) FILTER(WHERE baskets>=2)*1.0/count(*) multi_basket_share,
 count(*) FILTER(WHERE purchase_days>=2)*1.0/count(*) multi_day_share,
 count(*) FILTER(WHERE repeat_30d)*1.0/nullif(count(*) FILTER(WHERE eligible_30d),0) repeat_30d_share
FROM repeat_household GROUP BY window_id ORDER BY window_id;

-- name: repeat_intervals
SELECT window_id,count(*) completed_intervals,count(DISTINCT household_key) contributing_households,
 min(next_day-day) min_days,max(next_day-day) max_days,avg(next_day-day) mean_days,
 quantile_disc(next_day-day,0.25) p25_days,quantile_disc(next_day-day,0.5) median_days,
 quantile_disc(next_day-day,0.75) p75_days
FROM purchase_sequence WHERE next_day IS NOT NULL GROUP BY window_id ORDER BY window_id;
