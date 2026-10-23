# FMCG Retail Analytics

快消品零售经营与消费者行为分析，使用DuckDB SQL和Power BI DAX组织经营总览、品类分析、客户分层及促销诊断。

## 分析问题

- 销售金额变化来自购买家庭、购买频次还是篮均金额？
- 哪些品类贡献集中、哪些品类变动值得优先调查？
- 如何在固定窗口定义RFM和完整30天观察再购？
- 折扣覆盖、活动参与和资格对核销分别使用什么分母？

## 代码导航

| 模块 | 实现 |
|---|---|
| 数据审计 | [01_data_audit.sql](sql/01_data_audit.sql)：类型、缺失、主外键、异常及关联覆盖 |
| 品类范围与模型 | [02_category_scope_preview.sql](sql/02_category_scope_preview.sql)、[03_build_model.sql](sql/03_build_model.sql)：范围清单及事实/维度结构 |
| 经营与品类 | [04_operating_category.sql](sql/04_operating_category.sql)：完整等长窗口、去重覆盖、贡献及变动 |
| 客户与再购 | [05_customer_rfm_repeat.sql](sql/05_customer_rfm_repeat.sql)：RFM快照、窗口敏感性、完整跟踪 |
| 促销 | [06_promotion_analysis.sql](sql/06_promotion_analysis.sql)：折扣篮、活动、资格对及陈列/邮报覆盖 |
| Power BI | [07_powerbi_export.sql](sql/07_powerbi_export.sql)、[DAX度量](scripts/powerbi_measures.py)：Import模型导出和指标逻辑 |

方法说明：[数据模型](docs/model.md)、[指标口径](docs/metrics.md)、[运行说明](docs/reproduce.md)。

## 实现要点

交易行、购物篮、家庭快照和家庭活动/券资格保持不同粒度，关联前后核对行数与金额。全量交易用于对账，选定快消品用于主分析，排除与身份不足项分别保留。

经营比较采用完整、等长的相对周窗口；品类占比分母为同期全部主分析。RFM在活跃家庭中按分位点评分，同值同分，无购买家庭单列。观察再购要求完整后续窗口，跨日再购与同日多篮分开。

促销指标区分整篮、商品行、家庭活动对和家庭活动券资格对。未知不补零，观察截断活动单列。描述性关联不视为因果，也不据销售金额推断利润或营销ROI。

## 使用范围

这是SQL/DAX实现及分析执行器，**不是包含原始数据和完整建模驱动的端到端数据包**。分析执行器要求预先建立与模型契约一致的DuckDB数据库；审计和建模SQL也需要相应源视图、范围映射及执行上下文。详细前提见运行说明。

数据来源：[dunnhumby Source Files — The Complete Journey](https://www.dunnhumby.com/source-files/)。数据、说明书、逐户/逐篮记录、运行结果、报告截图、数据库和Power BI缓存不随仓库分发。获取与使用数据时应遵守提供方适用条款；项目不代表数据提供方认可。

本项目是个人分析项目。运营措施是待验证建议，不代表企业实习、已执行业务或已实现经营收益。DAY与周号按相对索引使用，不擅自转换为真实日历。
