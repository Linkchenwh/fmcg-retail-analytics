-- Inspection queries require prepared typed source views.
-- Source IDs remain strings, amounts use DECIMAL(18,2). No cleaning is applied.

-- name: transaction_baseline
SELECT COUNT(*) AS rows, COUNT(DISTINCT household_key) AS households,
       COUNT(DISTINCT BASKET_ID) AS baskets, COUNT(DISTINCT PRODUCT_ID) AS products,
       COUNT(DISTINCT STORE_ID) AS stores, SUM(SALES_VALUE) AS sales_value,
       MIN(DAY) AS first_day, MAX(DAY) AS last_day,
       MIN(WEEK_NO) AS first_week, MAX(WEEK_NO) AS last_week,
       COUNT(DISTINCT DAY) AS observed_days, COUNT(DISTINCT WEEK_NO) AS observed_weeks
FROM transaction_data;

-- name: weekly_coverage
SELECT WEEK_NO, MIN(DAY) AS first_day, MAX(DAY) AS last_day,
       COUNT(DISTINCT DAY) AS observed_days, COUNT(*) AS rows,
       COUNT(DISTINCT household_key) AS households
FROM transaction_data GROUP BY WEEK_NO ORDER BY WEEK_NO;

-- name: week_day_mapping
SELECT COUNT(*) FILTER (WHERE WEEK_NO<>floor((DAY+1)/7)+1) AS mapping_mismatches
FROM transaction_data;

-- name: monetary_representation
SELECT 'SALES_VALUE' AS field,
       COUNT(*) FILTER (WHERE NOT regexp_full_match(SALES_VALUE,'[+-]?[0-9]+(\.[0-9]{1,2})?')) AS nonstandard_format,
       COUNT(*) FILTER (WHERE abs(TRY_CAST(SALES_VALUE AS DOUBLE))>0
                        AND abs(TRY_CAST(SALES_VALUE AS DOUBLE))<0.0000000001) AS tiny_nonzero,
       COUNT(*) FILTER (WHERE TRY_CAST(SALES_VALUE AS DECIMAL(18,2)) IS NULL) AS cast_failures,
       MAX(abs(TRY_CAST(SALES_VALUE AS DOUBLE))) FILTER
          (WHERE NOT regexp_full_match(SALES_VALUE,'[+-]?[0-9]+(\.[0-9]{1,2})?')) AS max_nonstandard_magnitude
FROM raw.transaction_data
UNION ALL
SELECT 'RETAIL_DISC',
       COUNT(*) FILTER (WHERE NOT regexp_full_match(RETAIL_DISC,'[+-]?[0-9]+(\.[0-9]{1,2})?')),
       COUNT(*) FILTER (WHERE abs(TRY_CAST(RETAIL_DISC AS DOUBLE))>0
                        AND abs(TRY_CAST(RETAIL_DISC AS DOUBLE))<0.0000000001),
       COUNT(*) FILTER (WHERE TRY_CAST(RETAIL_DISC AS DECIMAL(18,2)) IS NULL),
       MAX(abs(TRY_CAST(RETAIL_DISC AS DOUBLE))) FILTER
          (WHERE NOT regexp_full_match(RETAIL_DISC,'[+-]?[0-9]+(\.[0-9]{1,2})?'))
FROM raw.transaction_data;

-- name: basket_consistency
WITH b AS (
  SELECT BASKET_ID, COUNT(DISTINCT household_key) AS households,
         COUNT(DISTINCT DAY) AS days, COUNT(DISTINCT STORE_ID) AS stores,
         COUNT(DISTINCT TRANS_TIME) AS times, COUNT(DISTINCT WEEK_NO) AS weeks,
         COUNT(*) AS detail_rows
  FROM transaction_data GROUP BY BASKET_ID
)
SELECT COUNT(*) AS baskets,
       COUNT(*) FILTER (WHERE households<>1) AS multiple_households,
       COUNT(*) FILTER (WHERE days<>1) AS multiple_days,
       COUNT(*) FILTER (WHERE stores<>1) AS multiple_stores,
       COUNT(*) FILTER (WHERE times<>1) AS multiple_times,
       COUNT(*) FILTER (WHERE weeks<>1) AS multiple_weeks,
       MAX(detail_rows) AS max_detail_rows FROM b;

-- name: quantity_amount_flags
SELECT MIN(QUANTITY) AS min_quantity, MAX(QUANTITY) AS max_quantity,
       quantile_cont(QUANTITY, [0.5,0.99,0.999]) AS quantity_quantiles,
       COUNT(*) FILTER (WHERE QUANTITY=0) AS zero_quantity,
       COUNT(*) FILTER (WHERE QUANTITY<0) AS negative_quantity,
       COUNT(*) FILTER (WHERE QUANTITY=0 AND SALES_VALUE<>0) AS zero_quantity_nonzero_sales,
       COUNT(*) FILTER (WHERE SALES_VALUE=0) AS zero_sales,
       COUNT(*) FILTER (WHERE SALES_VALUE<0) AS negative_sales,
       MIN(SALES_VALUE) AS min_sales, MAX(SALES_VALUE) AS max_sales,
       COUNT(*) FILTER (WHERE TRANS_TIME<0 OR TRANS_TIME>=2400 OR TRANS_TIME%100>=60) AS unusual_hhmm,
       COUNT(*) FILTER (WHERE SALES_VALUE+COUPON_DISC<0) AS negative_customer_payment_candidate,
       MIN(SALES_VALUE/NULLIF(QUANTITY,0)) AS min_sales_per_recorded_unit,
       MAX(SALES_VALUE/NULLIF(QUANTITY,0)) AS max_sales_per_recorded_unit
FROM transaction_data;

-- name: discount_signs
SELECT 'RETAIL_DISC' AS field,
       COUNT(*) FILTER (WHERE RETAIL_DISC<0) AS negative,
       COUNT(*) FILTER (WHERE RETAIL_DISC=0) AS zero,
       COUNT(*) FILTER (WHERE RETAIL_DISC>0) AS positive,
       MIN(RETAIL_DISC) AS minimum, MAX(RETAIL_DISC) AS maximum FROM transaction_data
UNION ALL
SELECT 'COUPON_DISC', COUNT(*) FILTER (WHERE COUPON_DISC<0),
       COUNT(*) FILTER (WHERE COUPON_DISC=0), COUNT(*) FILTER (WHERE COUPON_DISC>0),
       MIN(COUPON_DISC), MAX(COUPON_DISC) FROM transaction_data
UNION ALL
SELECT 'COUPON_MATCH_DISC', COUNT(*) FILTER (WHERE COUPON_MATCH_DISC<0),
       COUNT(*) FILTER (WHERE COUPON_MATCH_DISC=0), COUNT(*) FILTER (WHERE COUPON_MATCH_DISC>0),
       MIN(COUPON_MATCH_DISC), MAX(COUPON_MATCH_DISC) FROM transaction_data;

-- name: extreme_quantity_records
SELECT PRODUCT_ID, QUANTITY, SALES_VALUE, COUNT(*) AS records
FROM transaction_data WHERE QUANTITY>100 OR QUANTITY<=0
GROUP BY PRODUCT_ID, QUANTITY, SALES_VALUE ORDER BY QUANTITY DESC LIMIT 20;

-- name: household_observation
WITH h AS (
 SELECT household_key, MIN(DAY) AS first_day, MAX(DAY) AS last_day,
        COUNT(DISTINCT BASKET_ID) AS baskets
 FROM transaction_data GROUP BY household_key
)
SELECT COUNT(*) AS households, MIN(first_day) AS earliest_first_day,
       MAX(first_day) AS latest_first_day, MIN(last_day) AS earliest_last_day,
       MAX(last_day) AS latest_last_day,
       COUNT(*) FILTER (WHERE baskets=1) AS one_basket_households,
       quantile_cont(first_day,[0.25,0.5,0.75]) AS first_day_quartiles,
       quantile_cont(last_day,[0.25,0.5,0.75]) AS last_day_quartiles FROM h;

-- name: join_product_and_demographics
SELECT 'raw_transaction' AS join_case, COUNT(*) AS rows, SUM(SALES_VALUE) AS sales_value
FROM transaction_data
UNION ALL
SELECT 'left_product', COUNT(*), SUM(t.SALES_VALUE)
FROM transaction_data t LEFT JOIN product p ON t.PRODUCT_ID=p.PRODUCT_ID
UNION ALL
SELECT 'left_demographic', COUNT(*), SUM(t.SALES_VALUE)
FROM transaction_data t LEFT JOIN hh_demographic h ON t.household_key=h.household_key
UNION ALL
SELECT 'inner_demographic', COUNT(*), SUM(t.SALES_VALUE)
FROM transaction_data t INNER JOIN hh_demographic h ON t.household_key=h.household_key;

-- name: demographic_coverage
SELECT COUNT(*) AS transaction_rows, COUNT(DISTINCT t.household_key) AS households,
       COUNT(*) FILTER (WHERE h.household_key IS NOT NULL) AS matched_rows,
       COUNT(DISTINCT t.household_key) FILTER (WHERE h.household_key IS NOT NULL) AS matched_households,
       SUM(t.SALES_VALUE) FILTER (WHERE h.household_key IS NOT NULL) AS matched_sales_value
FROM transaction_data t LEFT JOIN hh_demographic h ON t.household_key=h.household_key;

-- name: foreign_keys
SELECT 'transaction_to_product' AS relation, COUNT(*) AS missing_rows
FROM transaction_data t WHERE NOT EXISTS (SELECT 1 FROM product p WHERE p.PRODUCT_ID=t.PRODUCT_ID)
UNION ALL
SELECT 'demographic_to_transaction_household', COUNT(*) FROM hh_demographic h
WHERE NOT EXISTS (SELECT 1 FROM transaction_data t WHERE t.household_key=h.household_key)
UNION ALL
SELECT 'campaign_assignment_to_campaign', COUNT(*) FROM campaign_table a
WHERE NOT EXISTS (SELECT 1 FROM campaign_desc d WHERE a.CAMPAIGN=d.CAMPAIGN)
UNION ALL
SELECT 'campaign_assignment_to_transaction_household', COUNT(*) FROM campaign_table a
WHERE NOT EXISTS (SELECT 1 FROM transaction_data t WHERE a.household_key=t.household_key)
UNION ALL
SELECT 'coupon_to_product', COUNT(*) FROM coupon c
WHERE NOT EXISTS (SELECT 1 FROM product p WHERE c.PRODUCT_ID=p.PRODUCT_ID)
UNION ALL
SELECT 'coupon_to_campaign', COUNT(*) FROM coupon c
WHERE NOT EXISTS (SELECT 1 FROM campaign_desc d WHERE c.CAMPAIGN=d.CAMPAIGN)
UNION ALL
SELECT 'redemption_to_campaign_coupon', COUNT(*) FROM coupon_redempt r
WHERE NOT EXISTS (SELECT 1 FROM coupon c WHERE r.CAMPAIGN=c.CAMPAIGN AND r.COUPON_UPC=c.COUPON_UPC)
UNION ALL
SELECT 'redemption_to_household_campaign', COUNT(*) FROM coupon_redempt r
WHERE NOT EXISTS (SELECT 1 FROM campaign_table a WHERE r.CAMPAIGN=a.CAMPAIGN AND r.household_key=a.household_key)
UNION ALL
SELECT 'causal_to_product', COUNT(*) FROM causal_data c
WHERE NOT EXISTS (SELECT 1 FROM product p WHERE c.PRODUCT_ID=p.PRODUCT_ID);

-- name: causal_join_coverage
SELECT COUNT(*) AS joined_rows, SUM(t.SALES_VALUE) AS joined_sales_value,
       COUNT(*) FILTER (WHERE c.PRODUCT_ID IS NULL) AS no_causal_match,
       COUNT(DISTINCT t.PRODUCT_ID) FILTER (WHERE c.PRODUCT_ID IS NULL) AS unmatched_products
FROM transaction_data t LEFT JOIN causal_data c
ON t.PRODUCT_ID=c.PRODUCT_ID AND t.STORE_ID=c.STORE_ID AND t.WEEK_NO=c.WEEK_NO;

-- name: causal_key_conflicts
WITH duplicates AS (
 SELECT PRODUCT_ID,STORE_ID,WEEK_NO FROM causal_data
 GROUP BY PRODUCT_ID,STORE_ID,WEEK_NO HAVING COUNT(*)>1
), selected AS (
 SELECT c.* FROM causal_data c JOIN duplicates d USING(PRODUCT_ID,STORE_ID,WEEK_NO)
), g AS (
 SELECT PRODUCT_ID,STORE_ID,WEEK_NO,COUNT(*) AS n,
        COUNT(DISTINCT display) AS displays,COUNT(DISTINCT mailer) AS mailers,
        MIN(CASE WHEN display='0' THEN 0 ELSE 1 END) AS min_display_flag,
        MAX(CASE WHEN display='0' THEN 0 ELSE 1 END) AS max_display_flag,
        MIN(CASE WHEN mailer='0' THEN 0 ELSE 1 END) AS min_mailer_flag,
        MAX(CASE WHEN mailer='0' THEN 0 ELSE 1 END) AS max_mailer_flag
 FROM selected GROUP BY PRODUCT_ID,STORE_ID,WEEK_NO
)
SELECT COUNT(*) AS duplicate_keys,
       COUNT(*) FILTER (WHERE displays>1) AS different_display_codes,
       COUNT(*) FILTER (WHERE mailers>1) AS different_mailer_codes,
       COUNT(*) FILTER (WHERE min_display_flag<>max_display_flag) AS contradictory_display_presence,
       COUNT(*) FILTER (WHERE min_mailer_flag<>max_mailer_flag) AS contradictory_mailer_presence FROM g;

-- name: customer_payment_candidate
WITH b AS (
 SELECT BASKET_ID,SUM(SALES_VALUE+COUPON_DISC) AS payment_candidate
 FROM transaction_data GROUP BY BASKET_ID
)
SELECT COUNT(*) FILTER (WHERE payment_candidate<0) AS negative_basket_candidates,
       MIN(payment_candidate) AS min_basket_candidate,
       (SELECT SUM(SALES_VALUE) FROM transaction_data WHERE QUANTITY=0) AS zero_quantity_sales_value
FROM b;

-- name: causal_affected_transactions
WITH duplicate_keys AS (
 SELECT PRODUCT_ID,STORE_ID,WEEK_NO FROM causal_data
 GROUP BY PRODUCT_ID,STORE_ID,WEEK_NO HAVING COUNT(*)>1
)
SELECT COUNT(*) AS affected_rows,SUM(t.SALES_VALUE) AS affected_sales_value
FROM transaction_data t WHERE EXISTS (
 SELECT 1 FROM duplicate_keys c WHERE t.PRODUCT_ID=c.PRODUCT_ID
 AND t.STORE_ID=c.STORE_ID AND t.WEEK_NO=c.WEEK_NO
);

-- name: causal_coverage_without_fanout
SELECT COUNT(*) AS source_rows,
       COUNT(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM causal_data c WHERE t.PRODUCT_ID=c.PRODUCT_ID
         AND t.STORE_ID=c.STORE_ID AND t.WEEK_NO=c.WEEK_NO)) AS matched_source_rows
FROM transaction_data t;

-- name: causal_domain
SELECT display, mailer, COUNT(*) AS rows,
       MIN(WEEK_NO) AS first_week, MAX(WEEK_NO) AS last_week
FROM causal_data GROUP BY display, mailer ORDER BY display, mailer;

-- name: causal_invalid_codes
SELECT COUNT(*) FILTER (WHERE display NOT IN ('0','1','2','3','4','5','6','7','9','A')) AS unknown_display,
       COUNT(*) FILTER (WHERE mailer NOT IN ('0','A','C','D','F','H','J','L','P','X','Z')) AS unknown_mailer,
       COUNT(DISTINCT PRODUCT_ID) AS products, COUNT(DISTINCT STORE_ID) AS stores,
       MIN(WEEK_NO) AS first_week, MAX(WEEK_NO) AS last_week FROM causal_data;

-- name: coupon_mapping_grain
WITH c AS (
 SELECT CAMPAIGN, COUPON_UPC, COUNT(*) AS rows, COUNT(DISTINCT PRODUCT_ID) AS products
 FROM coupon GROUP BY CAMPAIGN, COUPON_UPC
)
SELECT COUNT(*) AS campaign_coupon_pairs,
       COUNT(*) FILTER (WHERE products>1) AS pairs_with_multiple_products,
       MAX(products) AS max_products_per_coupon FROM c;

-- name: coupon_upc_campaigns
SELECT COUNT(*) AS upcs_in_multiple_campaigns FROM (
 SELECT COUPON_UPC FROM coupon GROUP BY COUPON_UPC HAVING COUNT(DISTINCT CAMPAIGN)>1
);

-- name: redemption_join_fanout
SELECT 'redemption_source' AS join_case, COUNT(*) AS rows FROM coupon_redempt
UNION ALL
SELECT 'join_raw_coupon_bridge', COUNT(*) FROM coupon_redempt r
LEFT JOIN coupon c ON r.CAMPAIGN=c.CAMPAIGN AND r.COUPON_UPC=c.COUPON_UPC
UNION ALL
SELECT 'join_distinct_coupon_keys', COUNT(*) FROM coupon_redempt r
LEFT JOIN (SELECT DISTINCT CAMPAIGN,COUPON_UPC FROM coupon) c
ON r.CAMPAIGN=c.CAMPAIGN AND r.COUPON_UPC=c.COUPON_UPC;

-- name: campaign_consistency
SELECT (SELECT COUNT(*) FROM campaign_desc WHERE END_DAY<START_DAY) AS inverted_periods,
       (SELECT COUNT(*) FROM campaign_table a JOIN campaign_desc d USING(CAMPAIGN)
        WHERE a.DESCRIPTION<>d.DESCRIPTION) AS type_mismatches,
       (SELECT COUNT(*) FROM coupon_redempt r JOIN campaign_desc d USING(CAMPAIGN)
        WHERE r.DAY<d.START_DAY OR r.DAY>d.END_DAY) AS redemptions_outside_period;

-- name: campaign_periods
SELECT DESCRIPTION, COUNT(*) AS campaigns, MIN(START_DAY) AS first_start,
       MAX(END_DAY) AS last_end, MIN(END_DAY-START_DAY+1) AS min_days,
       MAX(END_DAY-START_DAY+1) AS max_days FROM campaign_desc GROUP BY DESCRIPTION;

-- name: demographic_values
SELECT 'classification_1' AS field, classification_1 AS value, COUNT(*) AS households FROM hh_demographic GROUP BY classification_1
UNION ALL SELECT 'classification_2',classification_2,COUNT(*) FROM hh_demographic GROUP BY classification_2
UNION ALL SELECT 'classification_3',classification_3,COUNT(*) FROM hh_demographic GROUP BY classification_3
UNION ALL SELECT 'classification_4',classification_4,COUNT(*) FROM hh_demographic GROUP BY classification_4
UNION ALL SELECT 'classification_5',classification_5,COUNT(*) FROM hh_demographic GROUP BY classification_5
UNION ALL SELECT 'HOMEOWNER_DESC',HOMEOWNER_DESC,COUNT(*) FROM hh_demographic GROUP BY HOMEOWNER_DESC
UNION ALL SELECT 'KID_CATEGORY_DESC',KID_CATEGORY_DESC,COUNT(*) FROM hh_demographic GROUP BY KID_CATEGORY_DESC
ORDER BY field,value;

-- name: product_categories
SELECT COUNT(DISTINCT DEPARTMENT) AS departments, COUNT(DISTINCT COMMODITY_DESC) AS commodities,
       COUNT(DISTINCT SUB_COMMODITY_DESC) AS subcommodities,
       COUNT(*) FILTER (WHERE trim(CURR_SIZE_OF_PRODUCT)='') AS blank_sizes,
       COUNT(*) FILTER (WHERE COMMODITY_DESC='NO COMMODITY DESCRIPTION') AS unknown_commodity,
       COUNT(*) FILTER (WHERE SUB_COMMODITY_DESC='NO SUBCOMMODITY DESCRIPTION') AS unknown_subcommodity
FROM product;

-- name: category_parent_conflicts
SELECT 'commodity_to_department' AS relation, COUNT(*) AS labels_with_multiple_parents
FROM (SELECT COMMODITY_DESC FROM product GROUP BY COMMODITY_DESC HAVING COUNT(DISTINCT DEPARTMENT)>1)
UNION ALL
SELECT 'subcommodity_to_commodity', COUNT(*)
FROM (SELECT SUB_COMMODITY_DESC FROM product GROUP BY SUB_COMMODITY_DESC HAVING COUNT(DISTINCT COMMODITY_DESC)>1);

-- name: product_brands
SELECT BRAND, COUNT(*) AS products FROM product GROUP BY BRAND ORDER BY BRAND;

-- name: quantity_flags_by_department
SELECT p.DEPARTMENT, COUNT(*) AS rows, SUM(t.SALES_VALUE) AS sales_value,
       MIN(t.QUANTITY) AS min_quantity,MAX(t.QUANTITY) AS max_quantity
FROM transaction_data t LEFT JOIN product p USING(PRODUCT_ID)
WHERE t.QUANTITY=0 OR t.QUANTITY>100 GROUP BY p.DEPARTMENT ORDER BY rows DESC;

-- name: household_basket_product_conflicts
SELECT COUNT(*) AS repeated_basket_product_groups,
       COALESCE(SUM(n-1),0) AS extra_detail_rows,
       COUNT(*) FILTER (WHERE households>1) AS multiple_households,
       COUNT(*) FILTER (WHERE sales_values>1 OR quantities>1) AS differing_amount_or_quantity
FROM (
 SELECT BASKET_ID,PRODUCT_ID,COUNT(*) AS n,
        COUNT(DISTINCT household_key) AS households,COUNT(DISTINCT SALES_VALUE) AS sales_values,
        COUNT(DISTINCT QUANTITY) AS quantities
 FROM transaction_data GROUP BY BASKET_ID,PRODUCT_ID HAVING COUNT(*)>1
);
