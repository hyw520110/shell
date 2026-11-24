#!/usr/bin/env python3
"""SRC target selection and Nuclei result reporting helpers.

This module intentionally uses only the Python standard library. It does not
perform network requests or submit vulnerability reports.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import contextlib
import ipaddress
import json
import os
import re
import sys
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit


KNOWN_2LD = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "com.cn", "net.cn", "org.cn",
    "edu.cn", "gov.cn", "mil.cn", "ac.cn", "com.au", "net.au", "org.au",
    "co.jp", "com.hk", "com.tw", "co.kr",
}
SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4, "unknown": 5}
SUPPORTED_CHECKS = {"aspx-debug-mode", "ds-store"}
CLAIM_TTL_SECONDS = 24 * 60 * 60


def normalized_target(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    return value if "://" in value else "https://" + value


def host_of(value: str) -> str:
    parsed = urlsplit(normalized_target(value))
    host = parsed.hostname or parsed.path.split("/", 1)[0]
    return host.rstrip(".").lower()


def registrable_domain(value: str) -> str:
    host = host_of(value)
    if not host:
        return ""
    try:
        ipaddress.ip_address(host)
        return host
    except ValueError:
        pass
    labels = [part for part in host.split(".") if part]
    if len(labels) <= 2:
        return ".".join(labels)
    suffix = ".".join(labels[-2:])
    return ".".join(labels[-3:]) if suffix in KNOWN_2LD else suffix


def target_keys(value: str) -> set[str]:
    host = host_of(value)
    return {key for key in (host, registrable_domain(host)) if key}


def has_completed_report(directory: Path) -> bool:
    """Only successful reports make an output directory non-retryable."""
    if not directory.is_dir():
        return False
    structured = False
    for report in sorted(directory.glob("nuclei-*.md"), reverse=True):
        try:
            content = report.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        structured = structured or "Nuclei 命令退出码：" in content
        if "扫描健康状态：`incomplete`" in content or "扫描健康状态：`unknown`" in content:
            continue
        coverage = re.search(r"覆盖率\s*`(\d+(?:\.\d+)?)%`", content)
        if coverage and float(coverage[1]) < 95:
            continue
        if re.search(r"Nuclei 命令退出码：`0`", content):
            return True
    if structured:
        return False
    # Backward compatibility for scans created before the unified report
    # format.  A non-empty raw result file is evidence of a completed legacy
    # scan; a directory containing only a failed Markdown/log pair is not.
    for pattern in ("*.json", "*.jsonl", "*.txt"):
        if any(path.is_file() and path.stat().st_size > 0 for path in directory.glob(pattern)):
            return True
    return False


def read_history(path: Path, output_root: Optional[Path] = None) -> set[str]:
    result: set[str] = set()
    if path.exists():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                value = line.split("\t", 1)[0]
                if output_root:
                    directory = output_root / registrable_domain(value)
                    if directory.is_dir() and any(directory.glob("nuclei-*.md")) and not has_completed_report(directory):
                        continue
                result.update(target_keys(value))
    if output_root and output_root.is_dir():
        for child in output_root.iterdir():
            if (child.is_dir() and not child.name.startswith(".") and "." in child.name
                    and has_completed_report(child)):
                result.update(target_keys(child.name))
    return result


def claims_path(history: Path) -> Path:
    return Path(str(history) + ".claims")


def lock_path(history: Path) -> Path:
    return Path(str(history) + ".lock")


def read_claims(path: Path) -> set[str]:
    result: set[str] = set()
    if not path.exists():
        return result
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split("\t")
        if parts and parts[0].strip():
            if len(parts) > 1:
                try:
                    created = dt.datetime.fromisoformat(parts[1].strip())
                    if (dt.datetime.now(dt.timezone.utc) - created.astimezone(dt.timezone.utc)).total_seconds() > CLAIM_TTL_SECONDS:
                        continue
                except ValueError:
                    pass
            result.add(parts[0].strip().lower())
    return result


@contextlib.contextmanager
def history_lock(history: Path):
    history.parent.mkdir(parents=True, exist_ok=True)
    with lock_path(history).open("a+", encoding="utf-8") as handle:
        try:
            import fcntl
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        except ImportError as exc:
            raise RuntimeError("当前系统缺少 fcntl，无法安全锁定扫描历史") from exc
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def read_targets(path: Path) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        for row in csv.reader(handle, delimiter="\t"):
            if not row or not row[0].strip() or row[0].lstrip().startswith("#"):
                continue
            if len(row) < 2 or not row[1].strip():
                continue
            rows.append((row[0].strip(), normalized_target(row[1]), row[2].strip() if len(row) > 2 else ""))
    return rows


def append_history(path: Path, value: str) -> bool:
    domain = registrable_domain(value)
    if not domain:
        raise ValueError(f"无法从目标解析主域名：{value}")
    with history_lock(path):
        if target_keys(value) & read_history(path):
            remove_claim(path, domain, locked=True)
            return False
        with path.open("a", encoding="utf-8") as handle:
            handle.write(domain + "\n")
        remove_claim(path, domain, locked=True)
        return True


def claim_target(path: Path, value: str, force: bool = False, output_root: Optional[Path] = None) -> bool:
    domain = registrable_domain(value)
    if not domain:
        raise ValueError(f"无法从目标解析主域名：{value}")
    with history_lock(path):
        if not force and target_keys(value) & read_history(path, output_root):
            return False
        claims = claims_path(path)
        active = read_claims(claims)
        if domain in active:
            return False
        claims.parent.mkdir(parents=True, exist_ok=True)
        with claims.open("a", encoding="utf-8") as handle:
            handle.write(f"{domain}\t{dt.datetime.now().astimezone().isoformat(timespec='seconds')}\n")
        return True


def remove_claim(path: Path, domain: str, locked: bool = False) -> None:
    def rewrite() -> None:
        claim_file = claims_path(path)
        if not claim_file.exists():
            return
        kept = []
        for line in claim_file.read_text(encoding="utf-8", errors="replace").splitlines(True):
            if line.split("\t", 1)[0].strip().lower() != domain.lower():
                kept.append(line)
        if kept:
            claim_file.write_text("".join(kept), encoding="utf-8")
        else:
            claim_file.unlink(missing_ok=True)
    if locked:
        rewrite()
    else:
        with history_lock(path):
            rewrite()


def load_findings(path: Path) -> list[dict]:
    if not path.exists() or path.stat().st_size == 0:
        return []
    raw = path.read_text(encoding="utf-8", errors="replace").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
        if isinstance(data, dict):
            return [data]
    except json.JSONDecodeError:
        pass
    result: list[dict] = []
    for line in raw.splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            result.append(item)
    return result


def scalar(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    return str(value)


def md(value: object, limit: int = 4000) -> str:
    text = scalar(value).replace("\r", " ").replace("\n", " ").replace("|", "\\|").strip()
    return text[:limit] + ("…" if len(text) > limit else "")


def finding_key(item: dict) -> tuple[str, str, str, str]:
    info = item.get("info") or {}
    return (
        scalar(item.get("template-id")),
        scalar(item.get("matched-at") or item.get("url")),
        scalar(info.get("severity", "unknown")).lower(),
        scalar(item.get("type")),
    )


def deduplicate(findings: list[dict]) -> list[dict]:
    seen: set[tuple[str, str, str, str]] = set()
    result: list[dict] = []
    for item in findings:
        key = finding_key(item)
        if key not in seen:
            seen.add(key)
            result.append(item)
    return sorted(result, key=lambda item: (
        SEVERITY_ORDER.get(scalar((item.get("info") or {}).get("severity", "unknown")).lower(), 5),
        scalar(item.get("template-id")),
        scalar(item.get("matched-at") or item.get("url")),
    ))


def command_select(args: argparse.Namespace) -> int:
    history = read_history(Path(args.history), Path(args.output_root) if args.output_root else None)
    claimed = read_claims(claims_path(Path(args.history)))
    for vendor, target, source in read_targets(Path(args.targets)):
        if not target_keys(target) & history and registrable_domain(target) not in claimed:
            print(f"{vendor}\t{target}\t{source}")
            return 0
    return 2


def command_claim_next(args: argparse.Namespace) -> int:
    history_path = Path(args.history)
    output_root = Path(args.output_root) if args.output_root else None
    with history_lock(history_path):
        history = read_history(history_path, output_root)
        claimed = read_claims(claims_path(history_path))
        for vendor, target, source in read_targets(Path(args.targets)):
            domain = registrable_domain(target)
            if target_keys(target) & history or domain in claimed:
                continue
            claims = claims_path(history_path)
            claims.parent.mkdir(parents=True, exist_ok=True)
            with claims.open("a", encoding="utf-8") as handle:
                handle.write(f"{domain}\t{dt.datetime.now().astimezone().isoformat(timespec='seconds')}\n")
            print(f"{vendor}\t{target}\t{source}")
            return 0
    return 2


def command_claim_batch(args: argparse.Namespace) -> int:
    history_path = Path(args.history)
    output_root = Path(args.output_root) if args.output_root else None
    count = args.count
    claimed_targets = []
    with history_lock(history_path):
        history = read_history(history_path, output_root)
        claimed = read_claims(claims_path(history_path))
        claims = claims_path(history_path)
        claims.parent.mkdir(parents=True, exist_ok=True)
        now = dt.datetime.now().astimezone().isoformat(timespec='seconds')
        with claims.open("a", encoding="utf-8") as handle:
            for vendor, target, source in read_targets(Path(args.targets)):
                domain = registrable_domain(target)
                if target_keys(target) & history or domain in claimed:
                    continue
                handle.write(f"{domain}\t{now}\n")
                claimed.add(domain)
                claimed_targets.append((vendor, target, source))
                if len(claimed_targets) >= count:
                    break
    if not claimed_targets:
        return 2
    for vendor, target, source in claimed_targets:
        print(f"{vendor}\t{target}\t{source}")
    return 0


def command_is_listed(args: argparse.Namespace) -> int:
    # 主域名分组仅用于历史去重，不能用来自动授权所有关联子域。
    host = host_of(args.target)
    return 0 if any(host == host_of(target) for _, target, _ in read_targets(Path(args.targets))) else 1


def command_host(args: argparse.Namespace) -> int:
    parsed = urlsplit(normalized_target(args.target))
    host = parsed.hostname or ""
    if parsed.scheme not in {"http", "https"} or not host or parsed.username or parsed.password:
        raise ValueError("目标必须是不含凭据的 HTTP/HTTPS URL")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if any(not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?", label) for label in host.rstrip('.').split('.')):
            raise ValueError("目标主机名称无效")
    parsed.port  # 验证端口是否合法。
    print(host)
    return 0


def command_filter_scope(args: argparse.Namespace) -> int:
    if args.limit <= 0:
        raise ValueError("范围过滤数量上限必须为正整数")
    allowed: dict[str, list[str]] = {}
    for line in Path(args.allowlist).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "*" in line:
            continue
        value = normalized_target(line)
        parsed = urlsplit(value)
        if parsed.scheme in {"http", "https"} and parsed.hostname and not parsed.username and not parsed.password:
            allowed.setdefault(host_of(value), []).append(value)
    seen: set[str] = set()
    for line in Path(args.input).read_text(encoding="utf-8", errors="replace").splitlines():
        fields = line.split()
        if not fields:
            continue
        candidate = fields[0]
        candidates = allowed.get(host_of(candidate), [])
        for value in candidates:
            if "://" in candidate:
                actual, expected = urlsplit(candidate), urlsplit(value)
                default_port = {"http": 80, "https": 443}
                if (actual.scheme, actual.hostname, actual.port or default_port.get(actual.scheme)) != (expected.scheme, expected.hostname, expected.port or default_port.get(expected.scheme)):
                    continue
            if value not in seen:
                print(value)
                seen.add(value)
                if len(seen) >= args.limit:
                    return 0
    return 0


def command_is_scanned(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root) if args.output_root else None
    return 0 if target_keys(args.target) & read_history(Path(args.history), output_root) else 1


def command_claim_target(args: argparse.Namespace) -> int:
    output_root = Path(args.output_root) if args.output_root else None
    return 0 if claim_target(Path(args.history), args.target, args.force, output_root) else 1


def command_release_claim(args: argparse.Namespace) -> int:
    remove_claim(Path(args.history), registrable_domain(args.target))
    return 0


def command_domain(args: argparse.Namespace) -> int:
    value = registrable_domain(args.target)
    if not value:
        return 1
    print(value)
    return 0


def command_mark_scanned(args: argparse.Namespace) -> int:
    print("added" if append_history(Path(args.history), args.target) else "already-recorded")
    return 0


def command_checks(args: argparse.Namespace) -> int:
    seen: set[tuple[str, str]] = set()
    for item in load_findings(Path(args.json)):
        template_id = scalar(item.get("template-id"))
        target = scalar(item.get("matched-at") or item.get("url"))
        pair = (template_id, target)
        if template_id in SUPPORTED_CHECKS and target and pair not in seen:
            print(f"{template_id}\t{target}")
            seen.add(pair)
    return 0


def parse_scan_log(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    text = re.sub(r"\x1b\[[0-9;]*m", "", path.read_text(encoding="utf-8", errors="replace"))
    matches = re.findall(
        r"Templates:\s*(\d+).*?Hosts:\s*(\d+).*?Matched:\s*(\d+).*?Errors:\s*(\d+).*?Requests:\s*(\d+)/(\d+)\s*\((\d+)%\)",
        text,
    )
    result: dict[str, str] = {}
    if matches:
        templates, hosts, matched, errors, requests, total, percent = matches[-1]
        result.update({"templates": templates, "hosts": hosts, "matched": matched, "errors": errors, "requests": requests, "total_requests": total, "coverage": percent + "%"})
    durations = re.findall(r"Scan completed in\s+([^\n.]+(?:\.[0-9]+)?[a-z]*)", text)
    if durations:
        result["duration"] = durations[-1].strip()
    skipped = re.findall(r"Skipped\s+([^\n]+?)\s+from target list as found unresponsive(?: permanently| \d+ times)?", text)
    if skipped:
        result["skipped"] = str(len(skipped))
    loaded = re.findall(r"Templates loaded for current scan:\s*(\d+)", text)
    hosts = re.findall(r"Targets loaded for current scan:\s*(\d+)", text)
    if loaded:
        result.setdefault("templates", loaded[-1])
    if hosts:
        result.setdefault("hosts", hosts[-1])
    result["completed"] = str(bool(durations)).lower()
    return result


def scan_health(summary: dict[str, str]) -> str:
    if summary.get("skipped", "0") != "0":
        return "incomplete"
    if summary.get("coverage"):
        percent = float(summary["coverage"].rstrip("%"))
        return "complete" if percent >= 95 and summary.get("completed") == "true" else "incomplete"
    return "unknown"


def command_health(args: argparse.Namespace) -> int:
    summary = parse_scan_log(Path(args.log))
    state = scan_health(summary)
    print(f"扫描健康状态：{state}；覆盖率：{summary.get('coverage', '未知')}；错误：{summary.get('errors', '未知')}")
    return 0 if state == "complete" else 3


def command_analyze(args: argparse.Namespace) -> int:
    json_path = Path(args.json)
    output = Path(args.output)
    findings = deduplicate(load_findings(json_path))
    counts: dict[str, int] = {}
    for item in findings:
        severity = scalar((item.get("info") or {}).get("severity", "unknown")).lower() or "unknown"
        counts[severity] = counts.get(severity, 0) + 1

    output.parent.mkdir(parents=True, exist_ok=True)
    generated = dt.datetime.now().astimezone().isoformat(sep=" ", timespec="seconds")
    log_summary = parse_scan_log(Path(args.log)) if args.log else {}
    health = scan_health(log_summary)
    if str(args.scan_status) not in {"0", "manual"}:
        health = "incomplete"
    lines = [
        "# SRC 自动扫描报告", "",
        f"- 厂商：{md(args.vendor or '未提供')}",
        f"- 目标：`{md(args.target or '未提供')}`",
        f"- 生成时间：`{generated}`",
        f"- Nuclei 命令退出码：`{args.scan_status}`",
        f"- 扫描健康状态：`{health}`",
        f"- 初筛去重后匹配：**{len(findings)}**", "",
        "## 判定摘要", "",
    ]
    if log_summary:
        coverage = log_summary.get("coverage", "未知")
        lines += [
            "## 扫描覆盖摘要", "",
            f"- 模板/主机：`{log_summary.get('templates', '未知')}` / `{log_summary.get('hosts', '未知')}`",
            f"- 实际请求：`{log_summary.get('requests', '未知')}/{log_summary.get('total_requests', '未知')}`（覆盖率 `{coverage}`）",
            f"- Nuclei 错误：`{log_summary.get('errors', '未知')}`",
            f"- 跳过的无响应端点：`{log_summary.get('skipped', '0')}`",
            f"- 扫描耗时：`{log_summary.get('duration', '未知')}`", "",
        ]
    if findings:
        summary = ", ".join(f"{key}: {counts[key]}" for key in sorted(counts, key=lambda key: SEVERITY_ORDER.get(key, 5)))
        lines.append(f"严重性分布：{summary}")
    else:
        coverage = log_summary.get("coverage", "")
        if coverage and coverage != "100%":
            lines.append(f"未产生可解析的 Nuclei 匹配项，但扫描覆盖率仅为 {coverage}；这表示目标不可达或扫描不完整，不能据此判定目标不存在漏洞。")
        else:
            lines.append("未产生可解析的 Nuclei 匹配项；若命令退出码非 0，应先检查扫描日志和目标可达性。")
    lines += [
        "", "> 自动扫描结果是候选证据，不等于已确认漏洞；只有完成低影响复核并确认影响边界后，才应考虑提交漏洞报告。",
        "> 编排器默认排除高风险模板标签和执行协议；模板标签与指纹不能代替对实际请求的安全审查。", "",
    ]
    if json_path.exists():
        try:
            raw_link = os.path.relpath(json_path, output.parent)
        except ValueError:
            raw_link = str(json_path)
        lines += [f"原始 JSON：[{json_path.name}]({raw_link})", ""]
    if args.log and Path(args.log).exists():
        log_path = Path(args.log)
        try:
            log_link = os.path.relpath(log_path, output.parent)
        except ValueError:
            log_link = str(log_path)
        lines += [f"扫描日志：[{log_path.name}]({log_link})", ""]
    lines += ["## 扫描结果", ""]

    if not findings:
        lines.append("未发现匹配项。")
    else:
        for index, item in enumerate(findings, 1):
            info = item.get("info") or {}
            severity = scalar(info.get("severity", "unknown")).lower() or "unknown"
            name = scalar(info.get("name") or item.get("template-id") or "Finding")
            template_id = scalar(item.get("template-id") or "unknown")
            target = scalar(item.get("matched-at") or item.get("url") or args.target or "unknown")
            lines += [
                f"### {index}. {md(name)}", "", "| 字段 | 内容 |", "|---|---|",
                f"| 严重性 | `{md(severity)}` |", f"| 模板 ID | `{md(template_id)}` |",
                f"| 目标 | `{md(target)}` |", f"| 匹配位置 | `{md(item.get('matched-at') or target)}` |", "",
                f"**说明：** {md(info.get('description') or '模板未提供说明。')}", "",
                f"**修复建议：** {md(info.get('remediation') or '请结合服务端配置和复核结果制定修复方案。')}", "",
            ]
            if item.get("extracted-results"):
                lines += ["**提取结果：**", ""]
                lines.extend(f"- {md(value)}" for value in item["extracted-results"])
                lines.append("")
            if info.get("reference"):
                lines += ["**参考资料：**", ""]
                lines.extend(f"- {md(value)}" for value in info["reference"])
                lines.append("")
            lines += ["---", ""]
    output.write_text("\n".join(lines), encoding="utf-8")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="SRC 目标选择和 Nuclei 报告分析工具")
    sub = parser.add_subparsers(dest="command", required=True)
    select = sub.add_parser("select-next"); select.add_argument("--targets", required=True); select.add_argument("--history", required=True); select.add_argument("--output-root", default=""); select.set_defaults(func=command_select)
    listed = sub.add_parser("is-listed"); listed.add_argument("--targets", required=True); listed.add_argument("--target", required=True); listed.set_defaults(func=command_is_listed)
    host = sub.add_parser("host"); host.add_argument("--target", required=True); host.set_defaults(func=command_host)
    scope = sub.add_parser("filter-scope"); scope.add_argument("--input", required=True); scope.add_argument("--allowlist", required=True); scope.add_argument("--limit", type=int, default=20); scope.set_defaults(func=command_filter_scope)
    health = sub.add_parser("health"); health.add_argument("--log", required=True); health.set_defaults(func=command_health)
    scanned = sub.add_parser("is-scanned"); scanned.add_argument("--history", required=True); scanned.add_argument("--target", required=True); scanned.add_argument("--output-root", default=""); scanned.set_defaults(func=command_is_scanned)
    domain = sub.add_parser("domain"); domain.add_argument("--target", required=True); domain.set_defaults(func=command_domain)
    mark = sub.add_parser("mark-scanned"); mark.add_argument("--history", required=True); mark.add_argument("--target", required=True); mark.set_defaults(func=command_mark_scanned)
    checks = sub.add_parser("checks"); checks.add_argument("--json", required=True); checks.set_defaults(func=command_checks)
    claim_next = sub.add_parser("claim-next"); claim_next.add_argument("--targets", required=True); claim_next.add_argument("--history", required=True); claim_next.add_argument("--output-root", default=""); claim_next.set_defaults(func=command_claim_next)
    claim_batch = sub.add_parser("claim-batch"); claim_batch.add_argument("--targets", required=True); claim_batch.add_argument("--history", required=True); claim_batch.add_argument("--output-root", default=""); claim_batch.add_argument("--count", type=int, default=50); claim_batch.set_defaults(func=command_claim_batch)
    claim = sub.add_parser("claim-target"); claim.add_argument("--history", required=True); claim.add_argument("--target", required=True); claim.add_argument("--force", action="store_true"); claim.add_argument("--output-root", default=""); claim.set_defaults(func=command_claim_target)
    release = sub.add_parser("release-claim"); release.add_argument("--history", required=True); release.add_argument("--target", required=True); release.set_defaults(func=command_release_claim)
    analyze = sub.add_parser("analyze"); analyze.add_argument("--json", required=True); analyze.add_argument("--output", required=True); analyze.add_argument("--vendor", default=""); analyze.add_argument("--target", default=""); analyze.add_argument("--scan-status", default="unknown"); analyze.add_argument("--log", default=""); analyze.set_defaults(func=command_analyze)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return args.func(args)
    except (OSError, ValueError, csv.Error) as exc:
        print(f"[src-hunter-report] 错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
