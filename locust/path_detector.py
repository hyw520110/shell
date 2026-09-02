#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
路径探测工具 - 探测目标网站的有效路径
"""
import sys
import random
import requests
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse

# 导入公共配置
from config import USER_AGENTS

def detect_paths(host, max_paths=10, user_agent=None):
    """
    探测目标网站的有效路径
    
    Args:
        host: 目标主机 URL
        max_paths: 最大探测路径数
        user_agent: 自定义 User-Agent，默认随机选择
    
    Returns:
        路径列表
    """
    try:
        # 随机选择 User-Agent，模拟真实用户
        selected_ua = user_agent or random.choice(USER_AGENTS)
        
        headers = {
            "User-Agent": selected_ua,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        }
        
        response = requests.get(host, timeout=5, headers=headers)
        response.raise_for_status()
        
        soup = BeautifulSoup(response.text, 'html.parser')
        paths = set()

        parsed_host = urlparse(host)

        for link in soup.find_all('a', href=True):
            href = link['href']
            # 过滤掉锚点、外部链接等
            if href.startswith('#') or href.startswith('mailto:') or href.startswith('javascript:'):
                continue

            full_url = urljoin(host, href)
            parsed_url = urlparse(full_url)

            # 仅限同域名下的相对路径或绝对路径
            if parsed_url.netloc == parsed_host.netloc:
                path = parsed_url.path
                if path and path != '/' and '?' not in path:
                    paths.add(path)

            if len(paths) >= max_paths:
                break

        return sorted(list(paths))
    except requests.exceptions.RequestException as e:
        print(f"请求失败：{e}", file=sys.stderr)
        return []
    except Exception as e:
        print(f"错误：{e}", file=sys.stderr)
        return []

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)
    
    target_host = sys.argv[1]
    detected = detect_paths(target_host)
    print(";".join(detected))
