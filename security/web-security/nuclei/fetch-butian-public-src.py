#!/usr/bin/env python3
"""采集补天公益 SRC 公开厂商列表，生成 src-hunter 用的 TSV。

分页规律（2026-11 验证）：
  POST https://www.butian.net/Reward/pub
  multipart/form-data:  ajax=1, name=(搜索名), p=<页码>
  响应: {"status":1,"data":{"count":<总页数>,"current":<页>,"list":[
        {"company_id": "...", "company_name": "...", "avatar": "..."}]}}
  每页 30 条，count 为总页数（约 200）。

资产域名获取（2026-11 验证）：
  点击厂商行的“提交漏洞”会打开 /Loo/submit?cid=<company_id>，该页
  input[name=host] 的 value 即平台预填的厂商资产域名/IP。需要登录态
  (PHPSESSID 等 cookie)。脚本优先从 --cookie / BUTIAN_COOKIE 读取，
  否则通过 bb-browser 自动取当前标签的 document.cookie。

用法：
  ./fetch-butian-public-src.py --no-host          # 只采厂商列表（详情页 URL）
  ./enrich-butian-hosts.py                        # 用浏览器 API 补全真实域名

注意：逐页 GET /Loo/submit?cid=... 抓 host 在约 6000 次请求后会触发 WAF
（"Please enable JavaScript"）。批量补全请优先用 enrich-butian-hosts.py，
它走页面内 POST /Loo/getCompanyList，配合小批量（20）与间隔（1s）稳定可用。
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

API = "https://www.butian.net/Reward/pub"
SUBMIT_URL = "https://www.butian.net/Loo/submit?cid={cid}"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36")
REFERER = "https://www.butian.net/Reward/plan/2"
DEFAULT_OUTPUT = Path.home() / "nuclei_scan" / "butian-public-src-targets.tsv"
DEFAULT_CACHE = Path.home() / "nuclei_scan" / ".butian-host-cache.json"


def auto_cookie() -> str:
    """从 bb-browser 当前标签读取 document.cookie（需 daemon 已启动）。"""
    try:
        tabs = subprocess.run(
            ["bb-browser", "tab", "list"], capture_output=True, text=True, timeout=10
        ).stdout
        match = re.search(r"^\*\s*\[([^\]]+)\]", tabs, re.MULTILINE)
        if not match:
            return ""
        result = subprocess.run(
            ["bb-browser", "eval", "document.cookie", "--tab", match.group(1)],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        return result.strip('"')
    except Exception:  # noqa: BLE001 - 自动获取失败时回退到显式 cookie
        return ""


def fetch_page(page: int, timeout: float = 20, retries: int = 3) -> dict:
    boundary = "----ButianPublicSrcBoundary"
    fields = (("ajax", "1"), ("name", ""), ("p", str(page)))
    parts = [
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
        f"{value}\r\n"
        for name, value in fields
    ]
    parts.append(f"--{boundary}--\r\n")
    data = "".join(parts).encode("utf-8")

    req = urllib.request.Request(
        API,
        data=data,
        headers={
            "User-Agent": UA,
            "Referer": REFERER,
            "Accept": "application/json, text/plain, */*",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )
    last_error = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            if payload.get("status") != 1:
                raise RuntimeError(f"API status 非 1: {payload.get('info')}")
            return payload["data"]
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            if attempt < retries - 1:
                time.sleep(1 + attempt)
    raise RuntimeError(f"第 {page} 页采集失败: {last_error}")


def collect_companies(args: argparse.Namespace) -> list[tuple[str, str]]:
    first = fetch_page(args.first_page)
    total_pages = int(first.get("count") or 1)
    if args.max_pages:
        total_pages = min(total_pages, args.max_pages)

    companies: list[tuple[str, str]] = []
    for page in range(args.first_page, args.first_page + total_pages):
        data = first if page == args.first_page else fetch_page(page)
        for item in data.get("list") or []:
            name = str(item.get("company_name") or "").strip()
            cid = str(item.get("company_id") or "").strip()
            if name and cid:
                companies.append((name, cid))
        print(f"[厂商列表 页 {data.get('current', page)}/{total_pages}] 累计 {len(companies)}",
              file=sys.stderr, flush=True)
        if args.delay > 0:
            time.sleep(args.delay)

    seen: set[str] = set()
    unique: list[tuple[str, str]] = []
    for name, cid in companies:
        if cid in seen:
            continue
        seen.add(cid)
        unique.append((name, cid))
    return unique


def fetch_host(cid: str, cookie: str, timeout: float, retries: int) -> tuple[str, str]:
    """返回 (cid, host)。host 为空表示平台未预填资产。"""
    req = urllib.request.Request(
        SUBMIT_URL.format(cid=cid),
        headers={
            "Cookie": cookie,
            "User-Agent": UA,
            "Referer": REFERER,
            "Accept": "text/html,application/xhtml+xml",
        },
        method="GET",
    )
    last_error = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                html = resp.read().decode("utf-8", "replace")
            match = re.search(r'name="host"[^>]*?value="([^"]*)"', html)
            return cid, (match.group(1).strip() if match else "")
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            if attempt < retries - 1:
                time.sleep(0.5 * (attempt + 1))
    print(f"[警告] cid={cid} 获取 host 失败: {last_error}", file=sys.stderr)
    return cid, ""


def resolve_hosts(companies: list[tuple[str, str]], args: argparse.Namespace,
                  cookie: str) -> dict[str, str]:
    cache: dict[str, str] = {}
    if args.cache.exists():
        try:
            cache = json.loads(args.cache.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            cache = {}

    pending = [(name, cid) for name, cid in companies if cid not in cache]
    print(f"[资产域名] 共 {len(companies)} 家，缓存命中 {len(companies) - len(pending)}，"
          f"待请求 {len(pending)}", file=sys.stderr, flush=True)

    if pending:
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = {
                pool.submit(fetch_host, cid, cookie, args.timeout, args.retries): (name, cid)
                for name, cid in pending
            }
            done_count = 0
            for future in as_completed(futures):
                name, cid = futures[future]
                try:
                    _, host = future.result()
                except Exception:  # noqa: BLE001
                    host = ""
                cache[cid] = host
                done_count += 1
                if done_count % 200 == 0 or done_count == len(pending):
                    print(f"[资产域名] 进度 {done_count}/{len(pending)}",
                          file=sys.stderr, flush=True)
        args.cache.parent.mkdir(parents=True, exist_ok=True)
        args.cache.write_text(json.dumps(cache, ensure_ascii=False, indent=0), encoding="utf-8")
    return cache


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT),
                        help=f"输出 TSV（默认 {DEFAULT_OUTPUT}）")
    parser.add_argument("--cache", default=str(DEFAULT_CACHE),
                        help=f"host 缓存（默认 {DEFAULT_CACHE}）")
    parser.add_argument("--first-page", type=int, default=1)
    parser.add_argument("--max-pages", type=int, default=0, help="0=全部")
    parser.add_argument("--delay", type=float, default=0.1, help="厂商列表每页间隔")
    parser.add_argument("--with-curl-host", action="store_true",
                        help="用 curl 逐页取 host（易触发 WAF，不推荐；默认只采列表）")
    parser.add_argument("--cookie", default=os.environ.get("BUTIAN_COOKIE", ""),
                        help="登录 cookie（或设 BUTIAN_COOKIE）")
    parser.add_argument("--workers", type=int, default=10, help="域名获取并发数")
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--retries", type=int, default=2)
    args = parser.parse_args()

    args.cache = Path(args.cache).expanduser()
    args.output = Path(args.output).expanduser()

    try:
        companies = collect_companies(args)
    except Exception as exc:  # noqa: BLE001
        print(f"[错误] 厂商列表采集失败: {exc}", file=sys.stderr)
        sys.exit(1)

    rows: list[tuple[str, str, str]] = []
    if not args.with_curl_host:
        rows = [
            (name, f"https://www.butian.net/Company/{cid}", "补天公益SRC")
            for name, cid in companies
        ]
    else:
        cookie = args.cookie or auto_cookie()
        if not cookie:
            print("[错误] 未获取到登录 cookie。请先登录补天，或传 --cookie / BUTIAN_COOKIE；"
                  "也可用 --no-host 只生成详情页 URL。", file=sys.stderr)
            sys.exit(1)
        host_map = resolve_hosts(companies, args, cookie)
        for name, cid in companies:
            host = (host_map.get(cid) or "").strip()
            target = host or f"https://www.butian.net/Company/{cid}"
            rows.append((name, target, "补天公益SRC"))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerows(rows)

    with_host = sum(1 for _, target, _ in rows if not target.startswith("https://www.butian.net/Company/"))
    print(f"完成：{len(rows)} 家厂商，其中 {with_host} 家有域名/IP -> {args.output}")


if __name__ == "__main__":
    main()
