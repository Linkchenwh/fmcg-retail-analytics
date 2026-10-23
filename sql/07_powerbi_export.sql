-- Readonly model exports for an Import-mode star model. No raw source is changed.
-- Script supplies TEMP inputs rfm_input, repeat_input, campaign_input, window_input.

-- name: DimProduct
WITH categories AS (
 SELECT DISTINCT scope_status,display_group,coalesce(department,'（空白）') department,
 coalesce(commodity,'（空白）') commodity FROM dim.product
), keyed AS (
 SELECT *, 'C' || lpad(cast(row_number() OVER(ORDER BY scope_status,display_group,department,commodity) AS VARCHAR),4,'0') category_key
 FROM categories
)
SELECT p.product_id ProductId,p.scope_status ScopeStatus,p.display_group DisplayGroup,
 coalesce(p.department,'（空白）') Department,coalesce(p.commodity,'（空白）') Commodity,
 coalesce(p.subcategory,'（空白）') Subcategory,p.brand_type BrandType,p.size_text SizeText,
 p.manufacturer_id ManufacturerId,k.category_key CategoryKey,
 k.department || ' / ' || k.commodity || ' [' || k.display_group || ']' CategoryLabel
FROM dim.product p JOIN keyed k ON p.scope_status=k.scope_status AND p.display_group=k.display_group
 AND coalesce(p.department,'（空白）')=k.department AND coalesce(p.commodity,'（空白）')=k.commodity
ORDER BY p.product_id;

-- name: DimDay
SELECT day AS Day,week_no WeekNo,observed_days_in_week ObservedDaysInWeek,
 is_complete_observed_week IsCompleteWeek FROM dim.relative_day ORDER BY day;

-- name: DimHousehold
SELECT household_key HouseholdKey,has_demographics HasDemographics,
 classification_1 Classification1,classification_2 Classification2,classification_3 Classification3,
 classification_4 Classification4,classification_5 Classification5,
 homeowner_desc HomeownerDesc,kid_category_desc KidCategoryDesc,
 first_observed_day FirstObservedDay,last_observed_day LastObservedDay
FROM dim.household ORDER BY household_key;

-- name: DimSnapshotWindow
SELECT window_id WindowId,
 CASE window_id WHEN 'rfm_13w' THEN '13周：DAY615–705' ELSE '8周：DAY650–705' END WindowName,
 cast(first_day AS INTEGER) FirstDay,cast(last_day AS INTEGER) LastDay,
 cast(reference_day AS INTEGER) ReferenceDay,cast(observed_days AS INTEGER) ObservedDays
FROM window_input WHERE window_id IN('rfm_13w','rfm_8w') ORDER BY window_id;

-- name: FactSales
SELECT t.basket_id BasketId,t.product_id ProductId,t.household_key HouseholdKey,
 t.day AS Day,t.store_id StoreId,t.sales_value SalesValue,t.retail_disc RetailDisc,
 t.coupon_disc CouponDisc,t.coupon_match_disc CouponMatchDisc,
 CASE WHEN NOT t.has_promotion_context THEN 'uncovered'
 WHEN t.display_present IS NULL OR t.mailer_present IS NULL THEN 'presence_conflict'
 WHEN t.display_present=1 AND t.mailer_present=1 THEN 'display_and_mailer'
 WHEN t.display_present=1 THEN 'display_only' WHEN t.mailer_present=1 THEN 'mailer_only'
 ELSE 'known_neither' END ContextGroup,
 t.retail_disc<0 OR t.coupon_disc<0 OR t.coupon_match_disc<0 HasNegativeDiscount,
 t.retail_disc>0 OR t.coupon_disc>0 OR t.coupon_match_disc>0 HasPositiveException
FROM mart.transaction_all t;

-- name: FactCustomerSnapshot
SELECT window_id WindowId,household_key HouseholdKey,segment SegmentId,
 cast(nullif(recency,'') AS INTEGER) Recency,cast(frequency AS BIGINT) Frequency,
 cast(monetary AS DECIMAL(18,2)) Monetary,
 cast(nullif(last_purchase_day,'') AS INTEGER) LastPurchaseDay,
 cast(nullif(r_score,'') AS INTEGER) RScore,cast(nullif(f_score,'') AS INTEGER) FScore,
 cast(nullif(m_score,'') AS INTEGER) MScore,
 cast(observed_by_window_start AS BOOLEAN) ObservedByWindowStart
FROM rfm_input ORDER BY window_id,household_key;

-- name: FactRepeat
SELECT r.window_id WindowId,r.household_key HouseholdKey,s.segment SegmentId,
 cast(r.index_day AS INTEGER) IndexDay,cast(nullif(r.next_day,'') AS INTEGER) NextDay,
 cast(nullif(r.days_to_next,'') AS INTEGER) DaysToNext,
 cast(r.purchase_days AS INTEGER) PurchaseDays,cast(r.baskets AS BIGINT) Baskets,
 cast(r.eligible_30d AS BOOLEAN) Eligible30d,cast(nullif(r.repeat_30d,'') AS BOOLEAN) Repeat30d
FROM repeat_input r JOIN rfm_input s ON r.window_id=s.window_id AND r.household_key=s.household_key
ORDER BY r.window_id,r.household_key;

-- name: FactBasketPromotion
WITH basket AS (
 SELECT basket_id,min(household_key) household_key,min(day) AS day,min(store_id) store_id,
 sum(sales_value) sales_value,
 bool_or(retail_disc<0) loyalty,bool_or(coupon_disc<0 OR coupon_match_disc<0) coupon,
 bool_or(retail_disc>0 OR coupon_disc>0 OR coupon_match_disc>0) positive,
 sum(CASE WHEN retail_disc<0 OR coupon_disc<0 OR coupon_match_disc<0 THEN sales_value ELSE 0 END) discounted_line_sales,
 sum(CASE WHEN retail_disc<0 THEN -retail_disc ELSE 0 END) loyalty_abs,
 sum(CASE WHEN coupon_disc<0 THEN -coupon_disc ELSE 0 END) coupon_abs,
 sum(CASE WHEN coupon_match_disc<0 THEN -coupon_match_disc ELSE 0 END) match_abs
 FROM mart.transaction_fmcg GROUP BY basket_id
)
SELECT basket_id BasketId,household_key HouseholdKey,day AS Day,store_id StoreId,
 CASE WHEN positive THEN 'positive_exception' WHEN loyalty AND coupon THEN 'loyalty_and_coupon'
 WHEN loyalty THEN 'loyalty_only' WHEN coupon THEN 'coupon_only' ELSE 'no_recorded_negative_discount' END DiscountGroup,
 sales_value SalesValue,discounted_line_sales DiscountedLineSales,
 loyalty OR coupon HasNegativeDiscount,positive HasPositiveException,
 loyalty_abs LoyaltyAbs,coupon_abs CouponAbs,match_abs MatchAbs FROM basket;

-- name: DimCampaign
SELECT campaign_id CampaignId,campaign_type CampaignType,cast(start_day AS INTEGER) StartDay,
 cast(end_day AS INTEGER) EndDay,cast(observed_end_day AS INTEGER) ObservedEndDay,
 cast(observed_days AS INTEGER) ObservedDays,cast(observation_complete AS BOOLEAN) ObservationComplete,
 cast(pool_coupons AS BIGINT) PoolCoupons
FROM campaign_input ORDER BY cast(campaign_id AS INTEGER);

-- name: FactCampaign
SELECT campaign_id CampaignId,cast(assigned_households AS BIGINT) AssignedHouseholdCampaignPairs,
 cast(redeeming_households AS BIGINT) RedeemingHouseholdCampaignPairs,
 cast(valid_events AS BIGINT) ValidEvents,cast(redeemed_household_coupon_pairs AS BIGINT) RedeemedHouseholdCouponPairs,
 cast(nullif(eligible_household_coupon_pairs,'') AS BIGINT) EligiblePairs,
 cast(nullif(redeemed_eligible_pairs,'') AS BIGINT) RedeemedEligiblePairs
FROM campaign_input ORDER BY cast(campaign_id AS INTEGER);
