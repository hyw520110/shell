#!/usr/bin/env python3
"""通过补天前端 API getCompanyList 批量补全公益 SRC TSV 的域名/IP。

背景：直接请求 /Loo/submit?cid=<id> 抓 input[name=host] 在约 6000 次并发后
会触发 WAF（"Please enable JavaScript"）。但页面内的
POST /Loo/getCompanyList 不受拦截，返回的 company 字段中带有厂商资产域名。

本脚本在已登录的 Chrome（bb-browser）页面上下文中分批调用该 API，
把查到的域名写回 TSV 第二列。需要 daemon 已启动且已登录补天。
"""

import argparse
import csv
import json
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_TSV = Path.home() / "nuclei_scan" / "butian-public-src-targets.tsv"


def bb_eval(tab: str, js: str, timeout: int = 120) -> str:
    result = subprocess.run(
        ["bb-browser", "eval", js, "--tab", tab],
        capture_output=True, text=True, timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def find_tab() -> str:
    out = subprocess.run(
        ["bb-browser", "tab", "list"], capture_output=True, text=True, timeout=10
    ).stdout
    for line in out.splitlines():
        if line.startswith("*"):
            return line.split("]")[0].split("[")[-1]
    raise RuntimeError("没有当前标签，请先打开补天页面")


def get_token(tab: str) -> str:
    js = (
        "(document.querySelector('input[name=token]')||{}).value || ''"
    )
    return bb_eval(tab, js).strip().strip('"')


def query_batch(tab: str, names: list[str], token: str) -> list[list[str]]:
    payload = json.dumps(names, ensure_ascii=False)
    js = f"""
(async () => {{
  const names = {payload};
  const token = {json.dumps(token)};
  const out = [];
  for (const n of names) {{
    try {{
      const r = await fetch('/Loo/getCompanyList', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/x-www-form-urlencoded',
                  'X-Requested-With': 'XMLHttpRequest'}},
        body: 'company_name=' + encodeURIComponent(n) + '&token=' + token,
        credentials: 'same-origin'
      }});
      const d = await r.json();
      let host = '';
      if (d.status === 1 && Array.isArray(d.data)) {{
        const hosts = d.data.map(x => x.company)
          .filter(c => c && c.includes('.') && c !== n);
        host = hosts[0] || (d.data.some(x => x.company === n && n.includes('.')) ? n : '');
      }}
      out.push([n, host]);
    }} catch (e) {{ out.push([n, '']); }}
  }}
  return out;
}})()
"""
    raw = bb_eval(tab, js, timeout=180)
    return json.loads(raw)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tsv", default=str(DEFAULT_TSV))
    parser.add_argument("--tab", default="", help="bb-browser 标签 ID（默认当前标签）")
    parser.add_argument("--batch-size", type=int, default=150)
    parser.add_argument("--sleep", type=float, default=0.5, help="每批间隔秒")
    parser.add_argument("--limit", type=int, default=0, help="调试：只处理前 N 家")
    args = parser.parse_args()

    tsv = Path(args.tsv).expanduser()
    with tsv.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.reader(handle, delimiter="\t"))
    if not rows:
        print("[错误] TSV 为空", file=sys.stderr)
        sys.exit(1)

    # 已有真实域名的行直接跳过，便于分批多次运行、断点续传
    all_rows = rows
    pending = [
        row for row in rows
        if row[1].startswith("https://www.butian.net/Company/")
    ]
    rows = pending
    if args.limit:
        rows = rows[: args.limit]

    tab = args.tab or find_tab()
    token = get_token(tab)
    print(f"[信息] 使用标签 {tab}, token={token[:8]}..., 共 {len(rows)} 家", file=sys.stderr)
    if not token:
        print("[错误] 未取到 token，请先打开 /Loo/submit?cid=... 页面", file=sys.stderr)
        sys.exit(1)

    results: dict[str, str] = {}
    consecutive_empty = 0
    for start in range(0, len(rows), args.batch_size):
        batch = rows[start : start + args.batch_size]
        names = [row[0] for row in batch]
        try:
            pairs = query_batch(tab, names, token)
        except Exception as exc:  # noqa: BLE001
            print(f"[警告] 批次 {start} 失败: {exc}", file=sys.stderr)
            pairs = [[n, ""] for n in names]
        for name, host in pairs:
            results[name] = host
        filled = sum(1 for _, host in pairs if host)
        print(f"[进度] {start + len(batch)}/{len(rows)}，本批命中 {filled}/{len(batch)}",
              file=sys.stderr, flush=True)

        # WAF/token 失效时刷新页面重取 token，避免后面整段白跑
        if filled == 0:
            consecutive_empty += 1
            if consecutive_empty >= 2:
                print("[信息] 连续两批无结果，刷新页面重取 token", file=sys.stderr)
                subprocess.run(["bb-browser", "reload", "--tab", tab],
                               capture_output=True, timeout=30)
                time.sleep(3)
                token = get_token(tab)
                consecutive_empty = 0
        else:
            consecutive_empty = 0

        if args.sleep > 0:
            time.sleep(args.sleep)

    updated = 0
    for row in all_rows:
        host = results.get(row[0], "").strip()
        if host:
            row[1] = host
            updated += 1
    with tsv.open("w", encoding="utf-8", newline="") as handle:
        csv.writer(handle, delimiter="\t", lineterminator="\n").writerows(all_rows)

    print(f"完成：{updated}/{len(rows)} 家补全域名 -> {tsv}")


if __name__ == "__main__":
    main()
