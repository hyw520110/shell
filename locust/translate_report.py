#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Locust 压测报告汉化脚本 - 安全版本
只翻译显示给用户的 HTML 文本内容，避免破坏 JavaScript 代码
"""
import os
import sys
import glob
import re

# 翻译字典
TRANSLATE_DICT = {
    "Locust Test Report": "Locust 性能压测报告",
    "Test Report": "压测报告",
    "Test statistics": "测试统计",
    "Request Statistics": "请求统计详情",
    "Response Time Statistics": "响应时间统计",
    "Failures Statistics": "失败明细统计",
    "Exceptions Statistics": "异常明细统计",
    "Tasks Statistics": "任务分布统计",
    "Start time": "开始时间",
    "Stop time": "结束时间",
    "Elapsed time": "持续时间",
    "Run time": "运行时间",
    "Total Requests": "总请求数",
    "Total Failures": "总失败数",
    "Failure Ratio": "失败率",
    "Median Response Time": "响应时间中位数",
    "Average Response Time": "平均响应时间",
    "Min Response Time": "最小响应时间",
    "Max Response Time": "最大响应时间",
    "Average Content Size": "平均内容大小",
    "Requests/s": "请求/秒",
    "Failures/s": "失败/秒",
    "Current Requests per Second": "当前请求/秒",
    "Current Failure per Second": "当前失败/秒",
    "RPS": "RPS",
    "Type": "类型",
    "Name": "名称",
    "Requests": "请求数",
    "Fails": "失败数",
    "Median (ms)": "中位数",
    "Average (ms)": "平均值",
    "Min (ms)": "最小值",
    "Max (ms)": "最大值",
    "Average Size (bytes)": "平均大小(字节)",
    "Req/s": "请求/秒",
    "Statistics": "统计详情",
    "Failures": "失败明细",
    "Exceptions": "异常明细",
    "Tasks": "任务分布",
    "Charts": "图表",
    "Charts and graphs": "图表和图形",
    "Download Data": "下载数据",
    "Download CSV": "下载CSV",
    "Download HTML": "下载HTML",
    "Export Data": "导出数据",
    "Exception": "异常",
    "Count": "次数",
    "Message": "错误信息",
    "Traceback": "堆栈",
    "Occurrences": "出现次数",
    "Ratio": "占比",
    "Total Ratio": "总占比",
    "Tasks distribution": "任务分布",
    "Distribution": "分布",
    "Per Type": "按类型",
    "Per Name": "按名称",
    "Ratio Per Class": "类别占比详情",
    "Final ratio": "最终任务权重",
    "Aggregated": "汇总",
    "Response time": "响应时间",
    "Content size": "内容大小",
    "Response Time (ms)": "响应时间(毫秒)",
    "Number of Requests": "请求数",
    "Requests per Second": "每秒请求数(RPS)",
    "Failures per Second": "每秒失败数",
    "Number of Users": "并发用户数",
    "Response Times": "响应时间趋势",
    "Target Host": "目标主机",
    "Status": "状态",
    "Spawn rate": "启动速率",
    "Users": "用户数",
    "Hatching": "启动中",
    "Running": "运行中",
    "Stopped": "已停止",
    "Quitting": "退出中",
    "Swarming": "压测中",
    "ms": "毫秒",
    "seconds": "秒",
    "WebsiteUser": "虚拟用户类",
    "complexScenario": "复杂业务场景",
    "index": "首页接口",
}

def injectTranslationScript(content, html_file_path):
    """
    在 HTML 中注入翻译脚本引用
    """
    # 获取相对路径 - 从 HTML 文件所在目录到脚本所在目录的相对路径
    html_dir = os.path.dirname(html_file_path)
    script_dir = os.path.dirname(os.path.abspath(__file__))  # 获取 translate_report.py 所在目录
    
    # 翻译脚本位于 script_dir/assets/locust-zh.js
    script_file_path = os.path.join(script_dir, 'assets', 'locust-zh.js')
    
    # 计算相对路径
    relative_path = os.path.relpath(script_file_path, html_dir)
    
    # 注入翻译脚本标签
    translation_script = f'''    <!-- Locust 报告汉化脚本 -->
    <script src="{relative_path}"></script>
'''
    
    # 从文件末尾向前查找 </body> 标签，避免在 JavaScript 字符串字面量中错误插入
    last_body_end = content.rfind('</body>')
    if last_body_end != -1:
        content = content[:last_body_end] + translation_script + content[last_body_end:]
    else:
        last_html_end = content.rfind('</html>')
        if last_html_end != -1:
            content = content[:last_html_end] + translation_script + content[last_html_end:]
        else:
            # 如果没有找到 body 或 html 标签，直接追加到末尾
            content += translation_script
    
    return content

def process_file(file_path):
    """
    处理单个 HTML 文件
    """
    if not os.path.exists(file_path):
        print(f"文件不存在: {file_path}")
        return
    
    print(f"正在处理: {os.path.basename(file_path)}")
    
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        # 检查是否已经注入了翻译脚本
        if 'Locust 报告汉化脚本' in content:
            print(f"  已包含翻译脚本，跳过")
            return
        
        # 注入翻译脚本
        content = injectTranslationScript(content, file_path)
        
        # 写入文件
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"  翻译脚本注入完成")
            
    except Exception as e:
        print(f"  处理失败: {e}")

def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "."
    
    if os.path.isdir(target):
        print(f"处理目录: {target}")
        count = 0
        for f in glob.glob(os.path.join(target, "**/*.html"), recursive=True):
            # 跳过 visual_summary.html
            if "visual_summary.html" not in f:
                process_file(f)
                count += 1
        print(f"完成处理 {count} 个文件")
    elif os.path.isfile(target):
        print(f"处理文件: {target}")
        process_file(target)
    else:
        print(f"错误: 路径不存在: {target}")
        sys.exit(1)

if __name__ == "__main__":
    main()