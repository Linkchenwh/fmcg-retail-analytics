# 运行说明

## 环境

Python与DuckDB，依赖固定在requirements.txt。SQL采用DuckDB方言；DAX度量用于Power BI Import模型。

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

已有独立环境不需要重建。数据须自行从官方渠道取得并遵守适用条款；不要上传原始数据、说明书、数据库或运行导出。

## 前置模型

执行器要求一个已按[模型契约](model.md)构建并验证的DuckDB文件。审计及模型SQL可作为结构参考，但本仓库未包含源下载器、类型视图驱动或完整范围映射生成器，因此不能从原始ZIP一键建模。

## 只读运行分析

```powershell
.\.venv\Scripts\python.exe scripts/run_analysis.py --model data/processed/fmcg_retail.duckdb --analysis operating --output reports/operating
.\.venv\Scripts\python.exe scripts/run_analysis.py --model data/processed/fmcg_retail.duckdb --analysis customer_promotion --output reports/customer_promotion
```

执行器以read_only=True打开正式模型，按命名块顺序执行临时表和结果查询。客户与促销SQL必须在同一连接连续执行，因为促销依赖客户SQL的临时表。输出为本地JSON/CSV，不写回正式模型；为保护既有输出，目标目录必须为空或不存在。

## 核对重点

先核对源与模型版本、关联基数，再查全量及主分析金额、不同篮/家庭、窗口和空白。独立校验应从原始CSV使用Decimal和集合计算，不以同一SQL输出替代独立基准。

Power BI需要显式导入列类型、建立维度到事实关系，在Desktop实际刷新后运行DAX并保存实际结果。JSON结构检查不执行DAX，截图显示舍入值也不等于精确对账。篮均固定小数精度应单独明确，不能为一个指标放宽全部检查。

仓库不包含数据或运行结果；结果解释需保留样本、观察窗口、缺失属性和促销覆盖等限制。
