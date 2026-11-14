#!/usr/bin/env python3
"""檢查 R2 上最新一份 postgres 備份：多久前、檔案齊不齊、大小有沒有暴跌。

stdin 讀 `aws s3api list-objects-v2 --prefix postgres/ --output json` 的輸出，把報告印到 stdout；
有任何問題就 exit 1。由 .github/workflows/postgres-backup-check.yaml 呼叫，也可以在本機餵假資料測。

環境變數：
  MAX_AGE_HOURS   最新一份備份最多可以是幾小時前（預設 26）
  MIN_SIZE_RATIO  最新一份的總大小至少要是前一份的幾倍（預設 0.5）
"""
import datetime as dt
import json
import os
import sys

MAX_AGE_H = float(os.environ.get("MAX_AGE_HOURS", "26"))
MIN_RATIO = float(os.environ.get("MIN_SIZE_RATIO", "0.5"))


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def main():
    raw = sys.stdin.read().strip()
    objects = json.loads(raw).get("Contents", []) if raw else []

    # 依目錄分組：postgres/<時間戳或日期>/<檔名>
    runs = {}
    for o in objects:
        parts = o["Key"].split("/")
        if len(parts) != 3 or not parts[2]:
            continue
        modified = dt.datetime.fromisoformat(o["LastModified"].replace("Z", "+00:00"))
        runs.setdefault(parts[1], []).append((parts[2], o["Size"], modified))

    if not runs:
        print("問題：R2 的 postgres/ 底下沒有任何備份")
        return 1

    # 以目錄內最新的檔案時間排序（舊格式是日期、新格式是時間戳，名稱不一定能直接比）
    ordered = sorted(runs.items(), key=lambda kv: max(f[2] for f in kv[1]))
    latest_name, latest = ordered[-1]
    newest = max(f[2] for f in latest)
    age_h = (dt.datetime.now(dt.timezone.utc) - newest).total_seconds() / 3600
    total = sum(f[1] for f in latest)

    print(f"最新備份：postgres/{latest_name}/（{age_h:.1f} 小時前，{newest:%Y-%m-%d %H:%M} UTC，共 {len(runs)} 份）")
    for name, size, _ in sorted(latest):
        print(f"  {name} {human(size)}")

    problems = []
    if age_h > MAX_AGE_H:
        problems.append(f"最新一份是 {age_h:.1f} 小時前，超過 {MAX_AGE_H:g} 小時：備份可能停了")

    names = {f[0] for f in latest}
    if "globals.sql" not in names:
        problems.append("缺 globals.sql")
    dumps = [f for f in latest if f[0].endswith(".dump")]
    if not dumps:
        problems.append("沒有任何 .dump")
    problems += [f"{name} 是 0 byte" for name, size, _ in dumps if size == 0]

    if len(ordered) >= 2:
        prev_name, prev = ordered[-2]
        prev_total = sum(f[1] for f in prev)
        ratio = total / prev_total if prev_total else 1
        print(f"總大小 {human(total)}，前一份 {prev_name} {human(prev_total)}（{ratio:.0%}）")
        if ratio < MIN_RATIO:
            problems.append(f"總大小只有前一份的 {ratio:.0%}，dump 可能不完整")
        missing = {f[0] for f in prev} - names
        if missing:
            problems.append("比前一份少了：" + "、".join(sorted(missing)))

    for p in problems:
        print(f"問題：{p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
