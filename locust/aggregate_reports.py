#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
聚合所有压测会话数据并生成综合性能报告
优化：使用 Jinja2 模板引擎 + 增量报告更新
"""

import os
import pandas as pd
import glob
import sys
import re
import json
import hashlib
from datetime import datetime
from jinja2 import Environment, FileSystemLoader, select_autoescape

# 获取脚本所在目录
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(SCRIPT_DIR, 'templates')

# 缓存文件路径（改到用户主目录）
CACHE_FILE = os.path.join(os.path.expanduser("~"), '.locust_report_cache.json')


def load_cache():
    """加载缓存"""
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_cache(cache):
    """保存缓存"""
    try:
        with open(CACHE_FILE, 'w', encoding='utf-8') as f:
            json.dump(cache, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"警告：缓存保存失败：{e}")


def get_session_hash(session_path):
    """获取会话内容的哈希值，用于判断是否变更"""
    csv_files = glob.glob(os.path.join(session_path, "*_stats.csv"))
    if not csv_files:
        return None
    
    # 使用最新的 stats 文件计算哈希
    latest_csv = sorted(csv_files)[-1]
    try:
        with open(latest_csv, 'rb') as f:
            return hashlib.md5(f.read()).hexdigest()
    except Exception:
        return None


def aggregate_all_sessions(base_dir, incremental=True):
    """
    聚合所有会话数据并生成报告
    
    Args:
        base_dir: 报告基础目录
        incremental: 是否启用增量更新（默认启用）
    """
    sessions = [d for d in glob.glob(os.path.join(base_dir, "*/")) if os.path.isdir(d)]
    all_results = []
    primary_domain = "performance_summary"
    
    # 加载缓存
    cache = load_cache() if incremental else {}
    new_cache = {}
    has_changes = False

    # 获取环境变量
    raw_label = os.getenv("EXPORT_LABEL", "N/A")
    current_session_id = os.getenv("SESSION_ID", "NONE")
    
    # 找出最新的会话
    latest_session = None
    if current_session_id != "NONE":
        for session_path in sessions:
            session_name = os.path.basename(session_path.rstrip('/'))
            if current_session_id in session_name:
                latest_session = session_name
                break

    for session_path in sessions:
        session_name = os.path.basename(session_path.rstrip('/'))
        parts = session_name.split('_')
        domain = parts[0] if len(parts) > 0 else "Unknown"
        if primary_domain == "performance_summary" and domain != "Unknown":
            primary_domain = domain

        timestamp_str = "_".join(parts[1:]) if len(parts) > 1 else ""
        try:
            dt = datetime.strptime(timestamp_str, "%Y%m%d_%H%M%S")
            formatted_time = dt.strftime("%Y-%m-%d %H:%M:%S")
        except Exception:
            formatted_time = timestamp_str

        csv_files = glob.glob(os.path.join(session_path, "*_stats.csv"))
        html_reports = glob.glob(os.path.join(session_path, "*.html"))
        fail_files = glob.glob(os.path.join(session_path, "*_failures.csv"))
        if not csv_files:
            continue

        # 增量更新检查
        session_hash = get_session_hash(session_path)
        cache_key = session_name
        
        if incremental and cache_key in cache and cache[cache_key].get('hash') == session_hash:
            # 使用缓存数据
            print(f"  ℹ️  使用缓存：{session_name}")
            all_results.append(cache[cache_key]['data'])
            new_cache[cache_key] = cache[cache_key]
            continue
        
        has_changes = True
        detail_html = os.path.basename(html_reports[0]) if html_reports else ""
        detail_link = f"./{session_name}/{detail_html}" if detail_html else ""

        # 加载错误详情
        error_details = []
        if fail_files:
            try:
                fdf = pd.read_csv(fail_files[-1])
                error_details = fdf[['Type', 'Name', 'Message', 'Occurrences']].head(5).to_dict('records')
            except Exception:
                pass

        # 加载步骤数据
        steps = []
        for f in csv_files:
            try:
                u_match = re.search(r'_u(\d+)_', f)
                df = pd.read_csv(f)
                agg = df[df['Name'] == 'Aggregated'].iloc[0]
                steps.append({
                    "u": int(u_match.group(1)) if u_match else 0,
                    "rps": float(agg.get('Requests/s', 0)),
                    "rt": float(agg.get('Average Response Time', 0)),
                    "p95": float(agg.get('95%', 0)),
                    "p99": float(agg.get('99%', 0)),
                    "max": float(agg.get('Max Response Time', 0)),
                    "total": int(agg.get('Request Count', 0)),
                    "fail": int(agg.get('Failure Count', 0))
                })
            except Exception:
                continue

        if not steps:
            continue
        steps = sorted(steps, key=lambda x: x['u'])
        latest = steps[-1]

        # 计算失败率（用于标签生成）
        total_reqs = sum(s['total'] for s in steps)
        total_fails = sum(s['fail'] for s in steps)
        fail_rate = (total_fails / total_reqs * 100) if total_reqs > 0 else 0

        # 确定显示标签（智能生成）
        display_label = raw_label.strip() if raw_label else ""
        
        # 标签为空或为 N/A 时自动生成
        if not display_label or display_label == "N/A":
            # 判断是否是最新会话
            is_latest = (latest_session is not None and latest_session == session_name)

            if is_latest:
                # 最新会话：显示并发数 + 状态
                if fail_rate == 0:
                    status = "✅"
                elif fail_rate < 1:
                    status = "⚠️"
                else:
                    status = "🚨"
                display_label = f"{latest['u']}U {status}"
            else:
                # 历史会话：显示日期 + 并发数
                try:
                    date_part = session_name.split('_')[1][:8]  # YYYYMMDD
                    display_label = f"{date_part} {latest['u']}U"
                except Exception:
                    display_label = f"{latest['u']}U 历史"

        result_data = {
            "session": session_name,
            "domain": domain,
            "time": formatted_time,
            "label": display_label,
            "max_u": latest['u'],
            "max_rps": max(s['rps'] for s in steps),
            "rt": latest['rt'],
            "p95": latest['p95'],
            "p99": latest['p99'],
            "max_rt": max(s['max'] for s in steps),
            "fail_rate": (total_fails / total_reqs * 100) if total_reqs > 0 else 0,
            "errors": error_details,
            "rounds": len(steps),
            "steps": steps,
            "detail_link": detail_link,
            "csv_dir": f"./{session_name}/"
        }
        
        all_results.append(result_data)
        
        # 保存到缓存
        new_cache[cache_key] = {
            'hash': session_hash,
            'data': result_data
        }

    # 排序：升序用于趋势图，降序用于表格展示
    all_results_asc = sorted(all_results, key=lambda x: x['session'])
    all_results_desc = sorted(all_results, key=lambda x: x['session'], reverse=True)

    # 使用 Jinja2 模板渲染 HTML
    html_content = render_html_template(primary_domain, all_results_asc, all_results_desc)

    # 输出报告
    output_path = os.path.join(base_dir, f"{primary_domain}.html")
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(html_content)
    
    # 保存缓存
    if has_changes and incremental:
        save_cache(new_cache)
        print(f"  📦 缓存已更新，共 {len(new_cache)} 个会话")
    
    print(f"[SUCCESS] 综合报告已生成：{output_path}")
    return output_path


def render_html_template(primary_domain, all_results_asc, all_results_desc):
    """使用 Jinja2 渲染 HTML 模板"""
    # 初始化 Jinja2 环境
    env = Environment(
        loader=FileSystemLoader(TEMPLATE_DIR),
        autoescape=select_autoescape(['html', 'xml'])
    )

    # 加载模板
    template = env.get_template('report_template.html')

    # 渲染模板
    return template.render(
        primary_domain=primary_domain,
        all_results_asc=all_results_asc,
        all_results_desc=all_results_desc
    )


if __name__ == "__main__":
    # 支持 --no-incremental 参数禁用增量更新
    incremental = True
    base_directory = "."
    
    for arg in sys.argv[1:]:
        if arg == "--no-incremental":
            incremental = False
        else:
            base_directory = arg
    
    aggregate_all_sessions(base_directory, incremental)
