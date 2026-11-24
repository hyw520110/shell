#!/usr/bin/env python3
"""Dependency-free Markdown renderer for Nuclei JSON exports."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path


def load_items(path: Path) -> list[dict]:
    raw = path.read_text(encoding="utf-8", errors="replace").strip()
    if not raw:
        return []
    try:
        value = json.loads(raw)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
        return [value] if isinstance(value, dict) else []
    except json.JSONDecodeError:
        result = []
        for line in raw.splitlines():
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                result.append(value)
        return result


def text(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    return str(value)


def md(value: object, limit: int = 8000) -> str:
    value = text(value).replace("\r", " ").replace("\n", " ").replace("|", "\\|").strip()
    return value[:limit] + ("…" if len(value) > limit else "")


def escape_html(value: object) -> str:
    import html
    return html.escape(text(value))


def render_markdown(items: list[dict], output: Path) -> None:
    lines = ["# Nuclei 扫描报告", "", f"生成时间：{dt.datetime.now().astimezone().isoformat(sep=' ', timespec='seconds')}", ""]
    lines += ["## 结果摘要", "", f"匹配数量：**{len(items)}**", ""]
    if not items:
        lines.append("未发现匹配项。")
    for index, item in enumerate(items, 1):
        info = item.get("info") or {}
        name = info.get("name") or item.get("template-id") or "Finding"
        severity = info.get("severity") or "unknown"
        target = item.get("url") or item.get("matched-at") or "unknown"
        lines += [
            f"## {index}. {md(name)}", "", "| 字段 | 内容 |", "|---|---|",
            f"| 严重性 | `{md(severity)}` |",
            f"| 模板 ID | `{md(item.get('template-id') or 'unknown')}` |",
            f"| 目标 | `{md(target)}` |",
            f"| 匹配位置 | `{md(item.get('matched-at') or 'unknown')}` |", "",
            "### 说明", "", text(info.get("description") or "未提供"), "",
            "### 修复建议", "", text(info.get("remediation") or "未提供"), "",
        ]
        extracted = item.get("extracted-results") or []
        if extracted:
            lines += ["### 提取结果", ""]
            lines.extend(f"- {md(value)}" for value in extracted)
            lines.append("")
        references = info.get("reference") or []
        if references:
            lines += ["### 参考资料", ""]
            lines.extend(f"- {md(value)}" for value in references)
            lines.append("")
        lines += ["---", ""]
    output.write_text("\n".join(lines), encoding="utf-8")


def render_html(items: list[dict], output: Path) -> None:
    lines = [
        "<!doctype html>",
        '<html lang="zh-CN">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>Nuclei 扫描报告</title>",
        "<style>",
        'body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#202124;background:#f6f8fa}',
        "main,article{background:#fff;border:1px solid #d0d7de;border-radius:8px;padding:1rem 1.25rem;margin-bottom:1rem}",
        "table{border-collapse:collapse;width:100%;margin:.75rem 0}th,td{border:1px solid #d0d7de;padding:.5rem;text-align:left;vertical-align:top}th{background:#f6f8fa}",
        "code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}pre{white-space:pre-wrap;background:#f6f8fa;padding:.75rem;border-radius:6px;overflow:auto}",
        ".severity{font-weight:700}.critical,.high{color:#b42318}.medium{color:#b54708}.low{color:#175cd3}.info{color:#667085}",
        "</style>",
        "</head>",
        f"<body><main><h1>Nuclei 扫描报告</h1><p>生成时间：{dt.datetime.now().astimezone().isoformat(sep=' ', timespec='seconds')}</p></main>"
    ]
    if not items:
        lines.append("<article><p>未发现匹配项。</p></article>")
    for item in items:
        info = item.get("info") or {}
        name = info.get("name") or item.get("template-id") or "Finding"
        severity = info.get("severity") or "unknown"
        target = item.get("url") or item.get("matched-at") or "unknown"
        lines += [
            f"<article><h2>{escape_html(name)}</h2>",
            f'<p class="severity {escape_html(severity)}">严重性：{escape_html(severity)}</p>',
            "<table><tr><th>字段</th><th>内容</th></tr>",
            f"<tr><td>模板 ID</td><td>{escape_html(item.get('template-id') or 'unknown')}</td></tr>",
            f"<tr><td>目标</td><td>{escape_html(target)}</td></tr>",
            f"<tr><td>匹配位置</td><td>{escape_html(item.get('matched-at') or 'unknown')}</td></tr></table>",
            f"<h3>说明</h3><p>{escape_html(info.get('description') or '未提供')}</p>",
            f"<h3>修复建议</h3><p>{escape_html(info.get('remediation') or '未提供')}</p>"
        ]
        extracted = item.get("extracted-results") or []
        if extracted:
            lines += ["<h3>提取结果</h3><ul>"]
            lines.extend(f"<li>{escape_html(value)}</li>" for value in extracted)
            lines += ["</ul>"]
        
        curl_cmd = item.get("curl-command")
        if curl_cmd:
            lines += [f"<h3>复现命令</h3><pre>{escape_html(curl_cmd)}</pre>"]
            
        references = info.get("reference") or []
        if references:
            lines += ["<h3>参考资料</h3><ul>"]
            lines.extend(f"<li>{escape_html(value)}</li>" for value in references)
            lines += ["</ul>"]
        lines += ["</article>"]
    lines += ["</body></html>"]
    output.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Render Nuclei JSON as Markdown or HTML")
    parser.add_argument("--json", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--format", choices=["md", "html"], default="md")
    args = parser.parse_args()
    source = Path(args.json)
    output = Path(args.output)
    items = load_items(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    if args.format == "html":
        render_html(items, output)
    else:
        render_markdown(items, output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
