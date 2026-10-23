-- Read-only category inventory; not a final inclusion filter.
-- raw.* source tables must already exist. No cleaned model is created.

-- name: baseline
SELECT COUNT(*) AS detail_rows, COUNT(DISTINCT BASKET_ID) AS baskets,
       COUNT(DISTINCT household_key) AS households,
       SUM(TRY_CAST(SALES_VALUE AS DECIMAL(18,2))) AS sales_value
FROM raw.transaction_data;

-- name: department_inventory
SELECT p.DEPARTMENT AS department, COUNT(DISTINCT p.PRODUCT_ID) AS products,
       COUNT(DISTINCT t.PRODUCT_ID) AS traded_products,
       COUNT(t.PRODUCT_ID) AS detail_rows,
       COUNT(DISTINCT t.BASKET_ID) AS baskets,
       COUNT(DISTINCT t.household_key) AS households,
       COALESCE(SUM(TRY_CAST(t.SALES_VALUE AS DECIMAL(18,2))),0) AS sales_value
FROM raw.product p LEFT JOIN raw.transaction_data t USING(PRODUCT_ID)
GROUP BY p.DEPARTMENT ORDER BY sales_value DESC,p.DEPARTMENT;

-- name: commodity_inventory
SELECT p.DEPARTMENT AS department,p.COMMODITY_DESC AS commodity,
       COUNT(DISTINCT p.PRODUCT_ID) AS products,
       COUNT(DISTINCT t.PRODUCT_ID) AS traded_products,
       COUNT(t.PRODUCT_ID) AS detail_rows,
       COUNT(DISTINCT t.BASKET_ID) AS baskets,
       COUNT(DISTINCT t.household_key) AS households,
       COALESCE(SUM(TRY_CAST(t.SALES_VALUE AS DECIMAL(18,2))),0) AS sales_value
FROM raw.product p LEFT JOIN raw.transaction_data t USING(PRODUCT_ID)
GROUP BY p.DEPARTMENT,p.COMMODITY_DESC
ORDER BY p.DEPARTMENT,sales_value DESC,p.COMMODITY_DESC;

-- name: subcategory_inventory
SELECT p.DEPARTMENT AS department,p.COMMODITY_DESC AS commodity,
       p.SUB_COMMODITY_DESC AS subcategory,
       COUNT(DISTINCT p.PRODUCT_ID) AS products,
       COUNT(DISTINCT t.PRODUCT_ID) AS traded_products,
       COUNT(t.PRODUCT_ID) AS detail_rows,
       COUNT(DISTINCT t.BASKET_ID) AS baskets,
       COUNT(DISTINCT t.household_key) AS households,
       COALESCE(SUM(TRY_CAST(t.SALES_VALUE AS DECIMAL(18,2))),0) AS sales_value
FROM raw.product p LEFT JOIN raw.transaction_data t USING(PRODUCT_ID)
GROUP BY p.DEPARTMENT,p.COMMODITY_DESC,p.SUB_COMMODITY_DESC
ORDER BY p.DEPARTMENT,p.COMMODITY_DESC,sales_value DESC,p.SUB_COMMODITY_DESC;
