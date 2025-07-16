import re
import json
import os
import csv
import logging


# 设置日志级别
logging.basicConfig(level=logging.INFO, force=True)

# 定义翻译单词映射关系
field_mapping = {
    "Name": "名称",
    "Method": "方法",
    "Requests": "请求数",
    "Failures": "失败数",
    "Median Response Time": "中位响应时间",
    "Average Response Time": "平均响应时间",
    "Min Response Time": "最小响应时间",
    "Max Response Time": "最大响应时间",
    "Average Content Size": "平均内容大小",
    "Requests/s": "每秒请求数",
    "Failures/s": "每秒失败数",
    "Error": "错误",
    "Occurrences": "发生次数",
    "Count": "计数",
    "Message": "消息",
    "Traceback": "回溯",
    "Nodes": "节点",
    "Timestamp": "时间戳",
    "User Count": "用户数",
    "Type": "类型",
    "Request Count": "请求数",
    "Failure Count": "失败数",
    "Total Request Count": "总请求数",
    "Total Failure Count": "总失败数",
    "Total Median Response Time": "总中位响应时间",
    "Total Average Response Time": "总平均响应时间",
    "Total Min Response Time": "总最小响应时间",
    "Total Max Response Time": "总最大响应时间",
    "Total Average Content Size": "总平均内容大小",
    "Fails": "失败",
    "Median (ms)": "中位数(ms)",
    "Average (ms)": "平均值(ms)",
    "Min (ms)": "最小(ms)",
    "Max (ms)": "最大(ms)",
    "Average size (bytes)": "平均大小(字节)",
    "Current RPS": "当前每秒请求数",
    "Current Failures/s": "当前每秒失败数",
    "Aggregated": "聚合",
    "Request Statistics": "请求统计",
    "Response Time Statistics": "响应时间统计",
    "Failures Statistics": "失败统计",
    "Charts": "图表",
    "Final ratio": "最终比例",
    "Ratio Per Class": "每类比例",
    "Total Ratio": "总比例"
}

def translate_csv_fields(csv_path):
    """
    将 CSV 文件中的英文字段翻译为中文
    """
    # 修复临时文件路径问题，确保路径拼接正确
    temp_path = os.path.join(os.path.dirname(csv_path), f"temp_{os.path.basename(csv_path)}")
    logging.debug(f"- 临时文件路径: {temp_path}")  # 增加调试日志

    try:
        with open(csv_path, mode='r', encoding='utf-8') as infile, \
                open(temp_path, mode='w', encoding='utf-8', newline='') as outfile:
            reader = csv.DictReader(infile)

            # 记录原始表头
            original_headers = reader.fieldnames
            logging.debug(f"- 原始表头: {original_headers}")

            # 创建新的表头，格式为“英文(中文)”
            new_headers = [field_mapping.get(field, field) for field in original_headers]

            writer = csv.DictWriter(outfile, fieldnames=new_headers)

            # 记录转换后的表头
            logging.debug(f"- 转换为中文的表头: {new_headers}")

            # 写入表头
            writer.writeheader()

            # 写入数据行
            for row in reader:
                # 翻译字段值
                translated_row = {field_mapping.get(key, key): field_mapping.get(value, value) for key, value in row.items()}
                writer.writerow(translated_row)

        os.replace(temp_path, csv_path)
        logging.info(f"- 已翻译：{os.path.basename(csv_path)} ")
    except Exception as e:
        logging.error(f"- 转换 {os.path.basename(csv_path)} 时出错: {e}")

def translate_html_report(html_path):
    temp_path = os.path.join(os.path.dirname(html_path), f"temp_{os.path.basename(html_path)}")

    try:
        # 将 field_mapping 转换为 JSON 格式的字符串，确保正确处理非 ASCII 字符
        field_mapping_json = json.dumps(field_mapping, ensure_ascii=False, separators=(',', ':'))

        # 新增 JavaScript 代码以检测页面或表格就绪后进行翻译替换
        js_code = f"""
        <script>
            fieldMapping = {field_mapping_json};
            document.addEventListener('DOMContentLoaded', function() {{
                console.log("翻译脚本已加载");

                function isTableReady() {{
                    return document.querySelectorAll('table, div.table').length > 0;
                }}

                function translateTableHeaders() {{
                    const tables = document.querySelectorAll('table, div.table');
                    tables.forEach(table => {{
                        ['th', 'TH', 'td', 'TD'].forEach(selector => {{
                            table.querySelectorAll(selector).forEach(element => {{
                                let text = element.textContent.trim();
                                if (text.startsWith('#')) {{
                                    text = text.substring(1).trim();
                                }}
                                if (fieldMapping[text]) {{
                                    element.textContent = fieldMapping[text];
                                }}
                            }});
                        }});
                    }});
                }}

                // <h2> 和 <h3> 标签的翻译支持
                function translateHeadings() {{
                    const fieldMapping = {field_mapping_json}; 
                    ['h2', 'h3'].forEach(selector => {{
                        document.querySelectorAll(selector).forEach(element => {{
                            let text = element.textContent.trim();
                            if (fieldMapping[text]) {{
                                element.textContent = fieldMapping[text];
                            }}
                        }});
                    }});
                }}

                if (isTableReady()) {{
                    console.log("已就绪，开始翻译");
                    translateTableHeaders();
                    translateHeadings(); 
                }} else {{
                    console.log("未就绪，等待2秒后重试");
                    setTimeout(() => {{
                        if (isTableReady()) {{
                            console.log("已就绪，开始翻译");
                            translateTableHeaders();
                            translateHeadings(); 
                        }} else {{
                            console.error("未就绪，翻译失败");
                        }}
                    }}, 2000); // 等待2秒后再次尝试
                }}
            }});
        </script>
        """
        # print(js_code)

        # 读取原始 HTML 文件内容
        with open(html_path, 'r', encoding='utf-8') as f:
            html_content = f.read()

        # 使用正则表达式匹配 </body> 和 </html> 标签，并确保它们之间可以有换行符或空格
        body_end_pattern = re.compile(r'(</body>\s*</html>|</body>\s*\n\s*</html>|</body>\s+</html>)', re.IGNORECASE)
        if body_end_pattern.search(html_content):
            # 确保 JavaScript 代码插入到 </body> 和 </html> 标签之前
            html_content = body_end_pattern.sub(js_code + r'\g<0>', html_content)
        else:
            logging.warning(f"- 未找到 </body> 和 </html> 标签的组合，跳过插入 JavaScript: {html_path}")

        # 将修改后的内容写入临时文件
        with open(temp_path, 'w', encoding='utf-8') as f:
            f.write(html_content)

        # 替换原始文件
        os.replace(temp_path, html_path)
        logging.info(f"- 已翻译: {html_path}")

    except Exception as e:
        logging.error(f"- 转换失败: {str(e)}")

def main():
    """
    遍历当前目录及其子目录下的 .csv 和 .html 文件并翻译字段
    """
    for root, _, files in os.walk(os.getcwd()):
        for file in files:
            if file.endswith('.csv'):
                translate_csv_fields(os.path.join(root, file))
            elif file.endswith('.html'):
                translate_html_report(os.path.join(root, file))

if __name__ == "__main__":
    main()