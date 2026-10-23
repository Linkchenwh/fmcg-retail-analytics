"""DAX source, formats and folders for the four-page Import model."""
MEASURES=[]


def add(name,dax,folder='01 经营',fmt='#,0.00'):
    MEASURES.append(dict(name=name,expression=dax,displayFolder=folder,formatString=fmt))


main_filter='KEEPFILTERS(DimProduct[ScopeStatus] = "include")'
add('全量记录金额','SUM(FactSales[SalesValue])')
for name,expression,fmt in [
 ('主分析销售金额','SUM(FactSales[SalesValue])','#,0.00'),
 ('主分析交易行','COUNTROWS(FactSales)','#,0'),
 ('主分析购物篮','DISTINCTCOUNT(FactSales[BasketId])','#,0'),
 ('主分析购买家庭','DISTINCTCOUNT(FactSales[HouseholdKey])','#,0'),
 ('主分析不同商品','DISTINCTCOUNT(FactSales[ProductId])','#,0')]:
    add(name,f'CALCULATE({expression}, {main_filter})',fmt=fmt)
add('主分析篮均金额','DIVIDE([主分析销售金额], [主分析购物篮])')
add('每购买家庭篮数','DIVIDE([主分析购物篮], [主分析购买家庭])')
add('每购买家庭金额','DIVIDE([主分析销售金额], [主分析购买家庭])')
for name,num,den in [('分类金额占比','主分析销售金额','主分析销售金额'),
                     ('分类家庭覆盖','主分析购买家庭','主分析购买家庭'),
                     ('分类篮覆盖','主分析购物篮','主分析购物篮')]:
    add(name,f'DIVIDE([{num}], CALCULATE([{den}], REMOVEFILTERS(DimProduct)))','02 品类','0.00%')
candidate='''VAR _Candidates = CALCULATETABLE(
    ADDCOLUMNS(VALUES(DimProduct[CategoryKey]), "@Sales", [主分析销售金额]),
    REMOVEFILTERS(DimProduct))
VAR _Key = SELECTEDVALUE(DimProduct[CategoryKey])
VAR _Sales = [主分析销售金额]'''
add('品类金额排名',candidate+'''
RETURN IF(NOT ISBLANK(_Key) && NOT ISBLANK(_Sales),
    1 + COUNTROWS(FILTER(_Candidates, NOT ISBLANK([@Sales]) &&
        ([@Sales] > _Sales || ([@Sales] = _Sales && DimProduct[CategoryKey] < _Key)))))''','02 品类','#,0')
add('品类累计金额占比',candidate+'''
RETURN IF(NOT ISBLANK(_Key) && NOT ISBLANK(_Sales),
    DIVIDE(SUMX(FILTER(_Candidates, NOT ISBLANK([@Sales]) &&
        ([@Sales] > _Sales || ([@Sales] = _Sales && DimProduct[CategoryKey] <= _Key))), [@Sales]),
        CALCULATE([主分析销售金额], REMOVEFILTERS(DimProduct))))''','02 品类','0.00%')
add('最近8完整周金额','CALCULATE([主分析销售金额], REMOVEFILTERS(DimDay), DimDay[WeekNo] >= 94, DimDay[WeekNo] <= 101)')
add('前8完整周金额','CALCULATE([主分析销售金额], REMOVEFILTERS(DimDay), DimDay[WeekNo] >= 86, DimDay[WeekNo] <= 93)')
add('固定8周金额变化率','DIVIDE([最近8完整周金额] - [前8完整周金额], [前8完整周金额])',fmt='0.00%')
add('完整周环比','''VAR _Week = SELECTEDVALUE(DimDay[WeekNo])
VAR _Days = CALCULATE(COUNTROWS(DimDay), REMOVEFILTERS(DimDay), DimDay[WeekNo] = _Week)
VAR _PriorDays = CALCULATE(COUNTROWS(DimDay), REMOVEFILTERS(DimDay), DimDay[WeekNo] = _Week - 1)
VAR _Sales = CALCULATE([主分析销售金额], REMOVEFILTERS(DimDay), DimDay[WeekNo] = _Week)
VAR _Prior = CALCULATE([主分析销售金额], REMOVEFILTERS(DimDay), DimDay[WeekNo] = _Week - 1)
RETURN IF(NOT ISBLANK(_Week) && _Days = 7 && _PriorDays = 7, DIVIDE(_Sales - _Prior, _Prior))''',fmt='0.00%')

guard='HASONEVALUE(DimSnapshotWindow[WindowId])'
for name,expression,fmt in [
 ('快照家庭数','COUNTROWS(FactCustomerSnapshot)','#,0'),
 ('快照购买家庭','CALCULATE(COUNTROWS(FactCustomerSnapshot), KEEPFILTERS(FactCustomerSnapshot[Frequency] > 0))','#,0'),
 ('快照无购买家庭','CALCULATE(COUNTROWS(FactCustomerSnapshot), KEEPFILTERS(FactCustomerSnapshot[Frequency] = 0))','#,0'),
 ('快照金额','SUM(FactCustomerSnapshot[Monetary])','#,0.00'),
 ('快照篮数','SUM(FactCustomerSnapshot[Frequency])','#,0'),
 ('复购购买家庭','COUNTROWS(FactRepeat)','#,0'),
 ('30天可跟踪家庭','CALCULATE(COUNTROWS(FactRepeat), KEEPFILTERS(FactRepeat[Eligible30d] = TRUE()))','#,0'),
 ('30天再购家庭','CALCULATE(COUNTROWS(FactRepeat), KEEPFILTERS(FactRepeat[Eligible30d] = TRUE()), KEEPFILTERS(FactRepeat[Repeat30d] = TRUE()))','#,0'),
 ('跟踪不足家庭','CALCULATE(COUNTROWS(FactRepeat), KEEPFILTERS(FactRepeat[Eligible30d] = FALSE()))','#,0'),
 ('同窗多篮家庭','CALCULATE(COUNTROWS(FactRepeat), KEEPFILTERS(FactRepeat[Baskets] >= 2))','#,0'),
 ('同窗跨日家庭','CALCULATE(COUNTROWS(FactRepeat), KEEPFILTERS(FactRepeat[PurchaseDays] >= 2))','#,0')]:
    add(name,f'IF({guard}, {expression})','03 客户',fmt)
add('快照家庭占比','DIVIDE([快照家庭数], CALCULATE([快照家庭数], REMOVEFILTERS(DimSegment)))','03 客户','0.00%')
add('快照金额占比','DIVIDE([快照金额], CALCULATE([快照金额], REMOVEFILTERS(DimSegment)))','03 客户','0.00%')
add('30天观察再购比例','DIVIDE([30天再购家庭], [30天可跟踪家庭])','03 客户','0.00%')
add('同窗多篮比例','DIVIDE([同窗多篮家庭], [复购购买家庭])','03 客户','0.00%')
add('同窗跨日比例','DIVIDE([同窗跨日家庭], [复购购买家庭])','03 客户','0.00%')
MEASURES.append(dict(name='快照窗口提示',expression='SELECTEDVALUE(DimSnapshotWindow[WindowName], "请选择且仅选择一个客户快照窗口")',displayFolder='03 客户'))

fixed='REMOVEFILTERS(DimDay), DimDay[Day] >= 615, DimDay[Day] <= 705'
for name,expression,fmt in [
 ('91天商品行数','[主分析交易行]','#,0'),
 ('91天上下文匹配行',f'CALCULATE([主分析交易行], KEEPFILTERS(FactSales[ContextGroup] <> "uncovered"))','#,0'),
 ('91天折扣分析篮数','COUNTROWS(FactBasketPromotion)','#,0'),
 ('91天含负优惠篮','CALCULATE(COUNTROWS(FactBasketPromotion), KEEPFILTERS(FactBasketPromotion[HasNegativeDiscount] = TRUE()))','#,0'),
 ('91天整篮纳入金额','SUM(FactBasketPromotion[SalesValue])','#,0.00'),
 ('91天负优惠行金额','SUM(FactBasketPromotion[DiscountedLineSales])','#,0.00'),
 ('91天上下文金额','[主分析销售金额]','#,0.00')]:
    add(name,f'CALCULATE({expression}, {fixed})','04 促销',fmt)
add('91天上下文行覆盖','DIVIDE([91天上下文匹配行], CALCULATE([91天商品行数], REMOVEFILTERS(DimContext)))','04 促销','0.00%')
add('91天含负优惠篮比例','DIVIDE([91天含负优惠篮], [91天折扣分析篮数])','04 促销','0.00%')
add('91天分类篮均金额','DIVIDE([91天整篮纳入金额], [91天折扣分析篮数])','04 促销','#,0.00')

for name,column in [('分配家庭活动对','AssignedHouseholdCampaignPairs'),('核销家庭活动对','RedeemingHouseholdCampaignPairs'),('有效核销事件','ValidEvents')]:
    add(name,f'SUM(FactCampaign[{column}])','05 券活动','#,0')
add('家庭活动核销参与','DIVIDE([核销家庭活动对], [分配家庭活动对])','05 券活动','0.00%')
typea='CALCULATE(COUNTROWS(DimCampaign), KEEPFILTERS(DimCampaign[CampaignType] = "TypeA")) > 0'
for name,column in [('推导券资格对','EligiblePairs'),('已核销资格对','RedeemedEligiblePairs')]:
    add(name,f'IF({typea}, BLANK(), SUM(FactCampaign[{column}]))','05 券活动','#,0')
add('资格对核销覆盖','DIVIDE([已核销资格对], [推导券资格对])','05 券活动','0.00%')
MEASURES.append(dict(name='券资格口径提示',expression=f'IF({typea}, "包含TypeA：逐户券集合未知，资格覆盖留空", "TypeB/C：按活动分配和券池推导资格，非真实触达转化")',displayFolder='05 券活动'))
