import logging
import os
from locust import HttpUser, task, between, events
from datetime import datetime

# 设置日志级别
logging.basicConfig(level=logging.INFO)

# 获取环境变量中的额外路径
additional_paths = os.getenv('LOCUST_ADDITIONAL_PATHS', '').strip(';').split(';')
test_paths = [("/", "首页")] + [tuple(path.split(',')) for path in additional_paths if path]

class WebsiteUser(HttpUser):
    wait_time = between(1, 5)
    
    def on_start(self):
        self.paths = test_paths
    
    @task(3)  # 指定此任务的权重为3（即该任务被选中的概率是其他任务的三倍）
    def index(self):
        with self.client.get("/", catch_response=True) as response:
            if response.status_code != 200:
                response.failure(f"加载页面失败: {response.status_code}")
            else:
                logging.info("首页加载成功。")
    
    @task(1)  # 此任务的权重为1
    def custom_paths(self):
        for path, name in self.paths:
            if path == "/":
                continue  # 首页已经在单独的任务中处理
            with self.client.get(path, catch_response=True, name=name) as response:
                if response.status_code != 200:
                    response.failure(f"加载页面 '{name}' 失败: {response.status_code}")
                else:
                    logging.info(f"页面 '{name}' 加载成功。")

# 添加事件监听器以收集更多性能数据
@events.request.add_listener
def on_request(request_type, name, response_time, response_length, **kw):
    logging.info(f"请求类型 '{request_type}' 对于 '{name}' 在 {response_time}ms 内完成，响应大小为 {response_length} 字节")

# 测试结束时生成报告或清理资源
@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    logging.info("测试已结束。正在执行清理或报告生成...")
    report_filename = kwargs.get('report_file', f"{os.getcwd()}/report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.html")
    logging.info(f"报告已保存至 {report_filename}")

    # 解析 CSV 报告并判断是否达到性能瓶颈
    if hasattr(environment.stats, 'total'):
        total_stats = environment.stats.total
        average_response_time = total_stats.median_response_time
        error_rate = total_stats.fail_ratio
        
        logging.info(f"平均响应时间: {average_response_time:.2f} ms")
        logging.info(f"错误率: {error_rate:.2%}")

        if average_response_time > int(os.getenv('MAX_AVERAGE_RESPONSE_TIME', 2000)) or error_rate > float(os.getenv('MAX_ERROR_RATE', 0.05)):
            logging.warning("测试达到了性能瓶颈。")
        else:
            logging.info("测试未达到性能瓶颈，可以继续。")