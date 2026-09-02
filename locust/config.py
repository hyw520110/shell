#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Locust 压测公共配置
"""

# User-Agent 配置（避免被目标服务器拦截）
USER_AGENTS = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
]

# 默认 User-Agent
DEFAULT_USER_AGENT = USER_AGENTS[0]

# 请求头模板
DEFAULT_HEADERS = {
    "User-Agent": DEFAULT_USER_AGENT,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Accept-Encoding": "gzip, deflate, br",
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
}

# SLA 默认阈值
DEFAULT_SLA = {
    "max_avg_rt": 3000,      # 平均响应时间阈值 (ms)
    "max_p99_rt": 5000,      # P99 响应时间阈值 (ms)
    "max_fail_rate": 5.0,    # 最大失败率 (%)
}

# 压测默认参数
DEFAULT_BENCH = {
    "users": 100,
    "spawn_rate": 20,
    "run_time": 60,
    "multiplier": 1.5,
    "max_concurrency": 50000,
}

# 日志配置
LOG_CONFIG = {
    "level": "INFO",
    "format": "[%(levelname)s] %(message)s",
    "datefmt": "%Y-%m-%d %H:%M:%S",
}
