-- Requires a read-only audit.raw snapshot and a scope_input mapping.
-- One transaction row = basket_id + product_id. Amounts are retailer USD.
CREATE SCHEMA dim;
CREATE SCHEMA fact;
CREATE SCHEMA bridge;
CREATE SCHEMA mart;
CREATE SCHEMA meta;

CREATE TABLE dim.category_scope AS SELECT * FROM scope_input;
CREATE TABLE dim.product AS
SELECT trim(p.PRODUCT_ID) product_id, trim(p.MANUFACTURER) manufacturer_id,
       p.DEPARTMENT department_raw, p.COMMODITY_DESC commodity_raw,
       p.SUB_COMMODITY_DESC subcategory_raw, p.CURR_SIZE_OF_PRODUCT size_raw,
       nullif(trim(p.DEPARTMENT),'') department,
       nullif(trim(p.COMMODITY_DESC),'') commodity,
       nullif(trim(p.SUB_COMMODITY_DESC),'') subcategory,
       nullif(trim(p.CURR_SIZE_OF_PRODUCT),'') size_text,
       trim(p.BRAND) brand_type, s.path_id, s.scope_status, s.display_group,
       s.rule_id, s.reason scope_reason, s.pending_kind, s.scope_version,
       s.source_gift_label
FROM audit.raw.product p
LEFT JOIN dim.category_scope s ON p.DEPARTMENT=s.department
 AND p.COMMODITY_DESC=s.commodity AND p.SUB_COMMODITY_DESC=s.subcategory;
CREATE UNIQUE INDEX product_key ON dim.product(product_id);

CREATE TABLE fact.transaction_line AS
SELECT trim(BASKET_ID) basket_id, trim(PRODUCT_ID) product_id,
       trim(household_key) household_key, trim(STORE_ID) store_id,
       CAST(DAY AS INTEGER) AS day, CAST(WEEK_NO AS INTEGER) week_no,
       CAST(TRANS_TIME AS INTEGER) trans_time, CAST(QUANTITY AS BIGINT) quantity,
       SALES_VALUE sales_value_raw, RETAIL_DISC retail_disc_raw,
       COUPON_DISC coupon_disc_raw, COUPON_MATCH_DISC coupon_match_disc_raw,
       CAST(SALES_VALUE AS DECIMAL(18,2)) sales_value,
       CAST(RETAIL_DISC AS DECIMAL(18,2)) retail_disc,
       CAST(COUPON_DISC AS DECIMAL(18,2)) coupon_disc,
       CAST(COUPON_MATCH_DISC AS DECIMAL(18,2)) coupon_match_disc,
       CAST(SALES_VALUE AS DECIMAL(38,18))-CAST(SALES_VALUE AS DECIMAL(18,2)) sales_precision_residual,
       CAST(RETAIL_DISC AS DECIMAL(38,18))-CAST(RETAIL_DISC AS DECIMAL(18,2)) retail_precision_residual,
       CAST(QUANTITY AS BIGINT)=0 flag_zero_quantity,
       CAST(SALES_VALUE AS DECIMAL(18,2))=0 flag_zero_sales,
       CAST(RETAIL_DISC AS DECIMAL(18,2))>0 flag_positive_retail_disc,
       CAST(QUANTITY AS BIGINT)>1000 flag_quantity_above_1000,
       CAST(SALES_VALUE AS DECIMAL(18,2))+CAST(COUPON_DISC AS DECIMAL(18,2))<0 flag_negative_payment_candidate
FROM audit.raw.transaction_data;
CREATE UNIQUE INDEX transaction_key ON fact.transaction_line(basket_id, product_id);

CREATE TABLE dim.household AS
WITH observed AS (SELECT household_key, min(day) first_observed_day,
 max(day) last_observed_day FROM fact.transaction_line GROUP BY household_key)
SELECT o.*, h.household_key IS NOT NULL has_demographics,
       h.classification_1, h.classification_2, h.classification_3,
       h.classification_4, h.classification_5, h.HOMEOWNER_DESC homeowner_desc,
       h.KID_CATEGORY_DESC kid_category_desc
FROM observed o LEFT JOIN audit.raw.hh_demographic h ON o.household_key=trim(h.household_key);
CREATE UNIQUE INDEX household_key ON dim.household(household_key);
CREATE TABLE dim.store AS SELECT DISTINCT store_id FROM fact.transaction_line;
CREATE UNIQUE INDEX store_key ON dim.store(store_id);

CREATE TABLE dim.relative_day AS
WITH d AS (SELECT DISTINCT day,week_no FROM fact.transaction_line)
SELECT *, count(*) OVER (PARTITION BY week_no) observed_days_in_week,
 count(*) OVER (PARTITION BY week_no)=7 is_complete_observed_week FROM d;
CREATE UNIQUE INDEX day_key ON dim.relative_day(day);

-- Retain context only for keys actually used by transaction lines.
-- EXISTS avoids multiplying causal rows by the number of matching transactions.
CREATE TEMP TABLE transaction_promotion_keys AS
SELECT DISTINCT product_id, store_id, week_no FROM fact.transaction_line;
CREATE TABLE fact.promotion_context AS
SELECT trim(c.PRODUCT_ID) product_id, trim(c.STORE_ID) store_id,
       CAST(c.WEEK_NO AS INTEGER) week_no, count(*) source_rows,
       count(DISTINCT display) display_code_count, count(DISTINCT mailer) mailer_code_count,
       CASE WHEN count(DISTINCT display)=1 THEN min(display) END display_code,
       CASE WHEN count(DISTINCT mailer)=1 THEN min(mailer) END mailer_code,
       count(DISTINCT display)>1 display_code_conflict,
       count(DISTINCT mailer)>1 mailer_code_conflict,
       min(CASE WHEN display='0' THEN 0 ELSE 1 END) <>
         max(CASE WHEN display='0' THEN 0 ELSE 1 END) display_presence_conflict,
       min(CASE WHEN mailer='0' THEN 0 ELSE 1 END) <>
         max(CASE WHEN mailer='0' THEN 0 ELSE 1 END) mailer_presence_conflict,
       CASE WHEN min(CASE WHEN display='0' THEN 0 ELSE 1 END)=max(CASE WHEN display='0' THEN 0 ELSE 1 END)
         THEN min(CASE WHEN display='0' THEN 0 ELSE 1 END) END display_present,
       CASE WHEN min(CASE WHEN mailer='0' THEN 0 ELSE 1 END)=max(CASE WHEN mailer='0' THEN 0 ELSE 1 END)
         THEN min(CASE WHEN mailer='0' THEN 0 ELSE 1 END) END mailer_present
FROM audit.raw.causal_data c WHERE EXISTS (
 SELECT 1 FROM transaction_promotion_keys k WHERE k.product_id=trim(c.PRODUCT_ID)
 AND k.store_id=trim(c.STORE_ID) AND k.week_no=CAST(c.WEEK_NO AS INTEGER))
GROUP BY trim(c.PRODUCT_ID), trim(c.STORE_ID), CAST(c.WEEK_NO AS INTEGER);
CREATE UNIQUE INDEX promotion_key ON fact.promotion_context(product_id,store_id,week_no);

CREATE TABLE dim.campaign AS
SELECT trim(CAMPAIGN) campaign_id, trim(DESCRIPTION) campaign_type,
 CAST(START_DAY AS INTEGER) start_day, CAST(END_DAY AS INTEGER) end_day,
 CAST(END_DAY AS INTEGER)>711 extends_beyond_observation,
 least(CAST(END_DAY AS INTEGER),711) observed_end_day FROM audit.raw.campaign_desc;
CREATE UNIQUE INDEX campaign_key ON dim.campaign(campaign_id);
CREATE TABLE bridge.household_campaign AS
SELECT trim(household_key) household_key,trim(CAMPAIGN) campaign_id,
 trim(DESCRIPTION) campaign_type FROM audit.raw.campaign_table;
CREATE UNIQUE INDEX household_campaign_key ON bridge.household_campaign(household_key,campaign_id);
CREATE TABLE bridge.coupon_product AS
SELECT trim(CAMPAIGN) campaign_id,trim(COUPON_UPC) coupon_upc,
 trim(PRODUCT_ID) product_id,count(*) source_rows FROM audit.raw.coupon
GROUP BY trim(CAMPAIGN),trim(COUPON_UPC),trim(PRODUCT_ID);
CREATE UNIQUE INDEX coupon_product_key ON bridge.coupon_product(campaign_id,coupon_upc,product_id);
CREATE TABLE dim.coupon AS
SELECT campaign_id,coupon_upc,count(*) eligible_products,sum(source_rows) source_rows
FROM bridge.coupon_product GROUP BY campaign_id,coupon_upc;
CREATE UNIQUE INDEX coupon_key ON dim.coupon(campaign_id,coupon_upc);
CREATE TABLE fact.coupon_redemption AS
SELECT trim(household_key) household_key,CAST(DAY AS INTEGER) AS day,
 trim(CAMPAIGN) campaign_id,trim(COUPON_UPC) coupon_upc
FROM audit.raw.coupon_redempt;
CREATE UNIQUE INDEX redemption_key ON fact.coupon_redemption(household_key,day,campaign_id,coupon_upc);

-- No raw causal/coupon-product join in the business transaction view.
CREATE VIEW mart.transaction_all AS
SELECT t.*,p.path_id,p.department,p.commodity,p.subcategory,p.brand_type,
 p.scope_status,p.display_group,p.pending_kind,h.has_demographics,
 d.is_complete_observed_week,
 c.product_id IS NOT NULL has_promotion_context,
 c.source_rows promotion_source_rows,c.display_code,c.mailer_code,
 c.display_code_conflict,c.mailer_code_conflict,
 c.display_presence_conflict,c.mailer_presence_conflict,
 c.display_present,c.mailer_present
FROM fact.transaction_line t
LEFT JOIN dim.product p USING (product_id)
LEFT JOIN dim.household h USING (household_key)
LEFT JOIN dim.relative_day d USING (day,week_no)
LEFT JOIN fact.promotion_context c USING (product_id,store_id,week_no);
CREATE VIEW mart.transaction_fmcg AS SELECT * FROM mart.transaction_all WHERE scope_status='include';
CREATE VIEW mart.transaction_pending AS SELECT * FROM mart.transaction_all WHERE scope_status='pending';

-- Household/day/store attributes must be constant within each basket.
CREATE TABLE fact.basket AS
SELECT basket_id,min(household_key) household_key,min(day) AS day,min(week_no) week_no,
 min(store_id) store_id,min(trans_time) trans_time,count(*) line_count,
 sum(sales_value) sales_value,
 count(*) FILTER (WHERE scope_status='include') fmcg_line_count,
 coalesce(sum(sales_value) FILTER (WHERE scope_status='include'),0) fmcg_sales_value,
 coalesce(sum(sales_value) FILTER (WHERE scope_status='exclude'),0) excluded_sales_value,
 coalesce(sum(sales_value) FILTER (WHERE scope_status='pending'),0) pending_sales_value
FROM mart.transaction_all GROUP BY basket_id;
CREATE UNIQUE INDEX basket_key ON fact.basket(basket_id);
CREATE VIEW mart.basket_fmcg AS SELECT * FROM fact.basket WHERE fmcg_line_count>0;
