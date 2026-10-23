"""Run named analysis blocks against an existing model without writing it."""
import argparse
import csv
import json
import re
from pathlib import Path
import duckdb

ROOT=Path(__file__).resolve().parents[1]
FILES={"operating":["04_operating_category.sql"],
       "customer_promotion":["05_customer_rfm_repeat.sql","06_promotion_analysis.sql"]}

def run(model,analysis,output):
    model=Path(model).resolve();output=Path(output).resolve()
    if not model.is_file():raise FileNotFoundError(model)
    if output.exists() and any(output.iterdir()):raise FileExistsError("Output directory must be empty")
    if output==model or output in model.parents:raise ValueError("Choose a separate output directory")
    before=(model.stat().st_size,model.stat().st_mtime_ns)
    output.mkdir(parents=True,exist_ok=True)
    results={}
    con=duckdb.connect(str(model),read_only=True)
    con.execute("SET threads=2");con.execute("SET memory_limit='2GB'")
    try:
        for filename in FILES[analysis]:
            parts=re.split(r"^-- name: ([a-z_]+)\s*$",(ROOT/"sql"/filename).read_text(encoding="utf-8"),flags=re.M)
            for i in range(1,len(parts),2):
                name,query=parts[i:i+2]
                result=con.execute(query)
                if name.startswith("setup_"):continue
                columns=[d[0] for d in result.description]
                rows=result.fetchall()
                if name in results:raise ValueError("Duplicate output name: "+name)
                results[name]=[dict(zip(columns,row)) for row in rows]
                with (output/(name+".csv")).open("w",encoding="utf-8-sig",newline="") as f:
                    writer=csv.writer(f);writer.writerow(columns);writer.writerows(rows)
    finally:con.close()
    if before!=(model.stat().st_size,model.stat().st_mtime_ns):raise RuntimeError("Model metadata changed")
    (output/"results.json").write_text(json.dumps(results,ensure_ascii=False,default=str,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(dict(analysis=analysis,result_groups=len(results),rows=sum(map(len,results.values())))))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model",required=True,type=Path)
    p.add_argument("--analysis",required=True,choices=FILES)
    p.add_argument("--output",required=True,type=Path)
    a=p.parse_args();run(a.model,a.analysis,a.output)

if __name__=="__main__":main()
