#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
import re

# 1. 核心统计数据翻译
TRANS = {
    "Type": "类型", "Name": "名称", "# reqs": "请求数", "# fails": "失败数",
    "Avg": "平均值", "Min": "最小值", "Max": "最大值", "Med": "中位数",
    "req/s": "吞吐量(RPS)", "failures/s": "失败率/秒", "Aggregated": "汇总",
    "GET": "GET", "POST": "POST", "首页": "首页",
    "Error report": "错误统计报告",
    "# occurrences": "出现次数",
    "Error": "错误详情",
    "Response time percentiles (approximated)": "响应时间分位数(近似值)",
    "RetriesExceeded": "超出重试次数",
    "timed out": "超时",
    "Operation timed out": "操作超时",
    "nodename nor servname provided, or not known": "域名解析失败",
    "Too many open files": "文件句柄数过多",
    "Connection refused": "连接被拒绝"
}

# 2. 系统日志正则翻译映射
LOG_TRANS = [
    (r"Starting Locust ([\d\.]+)", r"正在启动 Locust 压测引擎 (版本 \1)"),
    (r"Run time limit set to (\d+) seconds", r"测试限时: \1 秒"),
    (r"Ramping to (\d+) users at a rate of ([\d\.]+) per second", r"压力爬坡: 目标 \1 并发，增长速率 \2/s"),
    (r"All users spawned: (.*) \((\d+) total users\)", r"状态汇报: 虚拟用户已全部就位 (共计 \2 个)"),
    (r"Stopping Locust", r"正在停止 Locust 引擎..."),
    (r"Test run stopped", r"测试运行已结束"),
    (r"CPU usage above 90%!", r"警告: CPU 使用率超过 90%! 可能会影响压测准确性"),
    (r"writing html report to file: (.*)", r"正在生成 HTML 报告: \1"),
]

HEADER_MARKER = "Type"
SEPARATOR_MARKER = "--------"

class ConsoleFormatter:
    def __init__(self):
        self.current_batch_has_header = False

    def translate_stats(self, text):
        for k, v in TRANS.items():
            if k in text:
                text = text.replace(k, v)
        return text

    def translate_log(self, line):
        # 提取日志内容部分（去除时间戳和模块名）
        # 兼容不同格式的日志
        match = re.search(r'(INFO|WARNING)/.*?: (.*)', line)
        if match:
            level = match.group(1)
            content = match.group(2)
            for pattern, repl in LOG_TRANS:
                if re.search(pattern, content):
                    translated = re.sub(pattern, repl, content)
                    # 重新拼回带颜色的中文日志
                    prefix = line[:line.find(level + "/")]
                    color = "0;36" if level == "INFO" else "0;33"
                    return f"{prefix}\033[{color}m[Locust系统] {translated}\033[0m\n"
        return line

    def process_line(self, line):
        # 处理统计表格表头
        if line.strip().startswith(HEADER_MARKER) or line.strip().startswith("# occurrences"):
            sys.stdout.write(self.translate_stats(line))
            self.current_batch_has_header = True
            return
        
        # 处理分隔线
        if SEPARATOR_MARKER in line:
            sys.stdout.write(line)
            return

        # 处理汇总行
        if "Aggregated" in line or "汇总" in line:
            sys.stdout.write(self.translate_stats(line))
            self.current_batch_has_header = False 
            return

        # 处理系统日志
        if "INFO/" in line or "WARNING/" in line:
            sys.stdout.write(self.translate_log(line))
            return

        # 处理其他包含翻译词汇的行 (如错误报告标题)
        if any(k in line for k in ["Error report", "Response time percentiles"]):
            sys.stdout.write(self.translate_stats(line))
            return

        # 默认输出翻译后的文本
        sys.stdout.write(self.translate_stats(line))
        sys.stdout.flush()

if __name__ == "__main__":
    formatter = ConsoleFormatter()
    try:
        for l in sys.stdin:
            formatter.process_line(l)
    except KeyboardInterrupt:
        pass
