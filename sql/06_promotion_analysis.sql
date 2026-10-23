-- Continues the temp tables from 05_customer_rfm_repeat.sql.
-- Discount/context: main FMCG; campaign/redemption: full original campaign scope.

-- name: discount_lines
WITH classified AS (
 SELECT w.window_id,l.*,
 CASE WHEN retail_disc>0 OR coupon_disc>0 OR coupon_match_disc>0 THEN 'positive_exception'
 WHEN retail_disc<0 AND (coupon_disc<0 OR coupon_match_disc<0) THEN 'loyalty_and_coupon'
 WHEN retail_disc<0 THEN 'loyalty_only'
 WHEN coupon_disc<0 OR coupon_match_disc<0 THEN 'coupon_only'
 ELSE 'no_recorded_negative_discount' END discount_group
 FROM main_line l JOIN analysis_windows w ON l.day BETWEEN w.first_day AND w.last_day WHERE w.use_promotion
)
SELECT window_id,discount_group,count(*) detail_rows,count(DISTINCT basket_id) baskets,
 count(DISTINCT household_key) households,sum(sales_value) sales_value,
 sum(CASE WHEN retail_disc<0 THEN -retail_disc ELSE 0 END) loyalty_abs,
 sum(CASE WHEN coupon_disc<0 THEN -coupon_disc ELSE 0 END) coupon_abs,
 sum(CASE WHEN coupon_match_disc<0 THEN -coupon_match_disc ELSE 0 END) match_abs
FROM classified GROUP BY window_id,discount_group ORDER BY window_id,discount_group;

-- name: discount_baskets
WITH classified AS (
 SELECT b.*,CASE WHEN positive_exception THEN 'positive_exception'
 WHEN has_loyalty_discount AND has_coupon_discount THEN 'loyalty_and_coupon'
 WHEN has_loyalty_discount THEN 'loyalty_only' WHEN has_coupon_discount THEN 'coupon_only'
 ELSE 'no_recorded_negative_discount' END discount_group
 FROM window_basket b JOIN analysis_windows w USING(window_id) WHERE w.use_promotion
)
SELECT window_id,discount_group,count(*) baskets,count(DISTINCT household_key) households,
 sum(sales_value) sales_value,avg(sales_value) mean_main_basket_sales,
 sum(discounted_line_sales) discounted_line_sales,sum(loyalty_abs) loyalty_abs,
 sum(coupon_abs) coupon_abs,sum(match_abs) match_abs
FROM classified GROUP BY window_id,discount_group ORDER BY window_id,discount_group;

-- name: segment_discounts
SELECT r.segment,count(DISTINCT r.household_key) households,count(b.basket_id) baskets,
 count(b.basket_id) FILTER(WHERE has_loyalty_discount OR has_coupon_discount) negative_discount_baskets,
 count(b.basket_id) FILTER(WHERE has_loyalty_discount OR has_coupon_discount)*1.0/nullif(count(b.basket_id),0) negative_discount_basket_share,
 coalesce(sum(b.sales_value),0) sales_value,coalesce(sum(b.discounted_line_sales),0) discounted_line_sales
FROM rfm r LEFT JOIN window_basket b ON b.household_key=r.household_key AND b.window_id=r.window_id
WHERE r.window_id='rfm_13w' GROUP BY r.segment ORDER BY sales_value DESC,r.segment;

-- name: setup_redemptions
CREATE TEMP TABLE redemption_checked AS
SELECT r.*,c.campaign_type,r.day BETWEEN c.start_day AND least(c.end_day,711) within_observed_campaign,
 EXISTS(SELECT 1 FROM bridge.household_campaign h WHERE h.household_key=r.household_key AND h.campaign_id=r.campaign_id) assigned,
 EXISTS(SELECT 1 FROM dim.coupon d WHERE d.campaign_id=r.campaign_id AND d.coupon_upc=r.coupon_upc) coupon_in_pool
FROM fact.coupon_redemption r JOIN dim.campaign c USING(campaign_id);

-- name: redemption_diagnostics
SELECT count(*) events,count(DISTINCT(household_key,campaign_id,coupon_upc)) household_coupon_pairs,
 count(*) FILTER(WHERE NOT within_observed_campaign) outside_campaign,
 count(*) FILTER(WHERE NOT assigned) unassigned,
 count(*) FILTER(WHERE NOT coupon_in_pool) unknown_coupon
FROM redemption_checked;

-- name: setup_coupon_eligibility
CREATE TEMP TABLE coupon_eligibility AS
SELECT h.household_key,h.campaign_id,d.coupon_upc,
 EXISTS(SELECT 1 FROM redemption_checked r WHERE r.household_key=h.household_key
 AND r.campaign_id=h.campaign_id AND r.coupon_upc=d.coupon_upc
 AND r.within_observed_campaign AND r.assigned AND r.coupon_in_pool) redeemed
FROM bridge.household_campaign h JOIN dim.coupon d USING(campaign_id)
JOIN dim.campaign c USING(campaign_id) WHERE c.campaign_type IN('TypeB','TypeC');

-- name: setup_campaign_metrics
CREATE TEMP TABLE campaign_metrics AS
WITH assigned AS (
 SELECT campaign_id,count(*) assigned_households FROM bridge.household_campaign GROUP BY campaign_id
), pools AS (
 SELECT campaign_id,count(*) pool_coupons FROM dim.coupon GROUP BY campaign_id
), redeemed AS (
 SELECT campaign_id,count(*) valid_events,count(DISTINCT household_key) redeeming_households,
 count(DISTINCT(household_key,coupon_upc)) redeemed_household_coupon_pairs
 FROM redemption_checked WHERE within_observed_campaign AND assigned AND coupon_in_pool GROUP BY campaign_id
), eligible AS (
 SELECT campaign_id,count(*) eligible_household_coupon_pairs,count(*) FILTER(WHERE redeemed) redeemed_eligible_pairs
 FROM coupon_eligibility GROUP BY campaign_id
)
SELECT c.campaign_id,c.campaign_type,c.start_day,c.end_day,
 NOT c.extends_beyond_observation observation_complete,c.observed_end_day,
 c.observed_end_day-c.start_day+1 observed_days,a.assigned_households,p.pool_coupons,
 coalesce(r.valid_events,0) valid_events,coalesce(r.redeeming_households,0) redeeming_households,
 coalesce(r.redeemed_household_coupon_pairs,0) redeemed_household_coupon_pairs,
 coalesce(r.redeeming_households,0)*1.0/nullif(a.assigned_households,0) household_participation,
 e.eligible_household_coupon_pairs,e.redeemed_eligible_pairs,
 e.redeemed_eligible_pairs*1.0/nullif(e.eligible_household_coupon_pairs,0) eligible_pair_redemption_share
FROM dim.campaign c JOIN assigned a USING(campaign_id) JOIN pools p USING(campaign_id)
LEFT JOIN redeemed r USING(campaign_id) LEFT JOIN eligible e USING(campaign_id);

-- name: campaigns
SELECT * FROM campaign_metrics ORDER BY cast(campaign_id AS INTEGER);

-- name: campaign_type_summary
SELECT campaign_type,observation_complete,count(*) campaigns,
 sum(assigned_households) assigned_household_campaign_pairs,
 sum(redeeming_households) redeeming_household_campaign_pairs,
 sum(valid_events) valid_events,sum(redeemed_household_coupon_pairs) redeemed_household_coupon_pairs,
 sum(redeeming_households)*1.0/sum(assigned_households) household_campaign_participation,
 sum(eligible_household_coupon_pairs) eligible_household_coupon_pairs,
 sum(redeemed_eligible_pairs) redeemed_eligible_pairs,
 sum(redeemed_eligible_pairs)*1.0/nullif(sum(eligible_household_coupon_pairs),0) eligible_pair_redemption_share
FROM campaign_metrics GROUP BY campaign_type,observation_complete ORDER BY campaign_type,observation_complete DESC;

-- name: coupon_product_scope
SELECT p.scope_status,count(*) distinct_coupon_product_mappings,
 count(DISTINCT(b.campaign_id,b.coupon_upc)) coupons_with_this_scope
FROM bridge.coupon_product b JOIN dim.product p USING(product_id)
GROUP BY p.scope_status ORDER BY p.scope_status;

-- name: context_status
WITH classified AS (
 SELECT w.window_id,l.*,
 CASE WHEN NOT has_promotion_context THEN 'uncovered'
 WHEN display_present IS NULL OR mailer_present IS NULL THEN 'presence_conflict'
 WHEN display_present=1 AND mailer_present=1 THEN 'display_and_mailer'
 WHEN display_present=1 THEN 'display_only' WHEN mailer_present=1 THEN 'mailer_only'
 ELSE 'known_neither' END context_group
 FROM main_line l JOIN analysis_windows w ON l.day BETWEEN w.first_day AND w.last_day WHERE w.use_promotion
)
SELECT window_id,context_group,count(*) detail_rows,count(DISTINCT basket_id) baskets,
 count(DISTINCT household_key) households,count(DISTINCT(product_id,store_id,week_no)) observed_product_store_week_keys,
 sum(sales_value) sales_value
FROM classified GROUP BY window_id,context_group ORDER BY window_id,context_group;

-- name: context_coverage_by_group
SELECT w.window_id,l.display_group,count(*) detail_rows,
 count(*) FILTER(WHERE has_promotion_context) matched_rows,
 count(*) FILTER(WHERE has_promotion_context AND display_present IS NOT NULL AND mailer_present IS NOT NULL) resolved_rows,
 count(*) FILTER(WHERE has_promotion_context AND (display_present IS NULL OR mailer_present IS NULL)) conflict_rows,
 sum(sales_value) sales_value,
 coalesce(sum(sales_value) FILTER(WHERE has_promotion_context),0) matched_sales_value,
 count(*) FILTER(WHERE has_promotion_context)*1.0/count(*) row_coverage
FROM main_line l JOIN analysis_windows w ON l.day BETWEEN w.first_day AND w.last_day WHERE w.use_promotion
GROUP BY w.window_id,l.display_group ORDER BY w.window_id,l.display_group;
