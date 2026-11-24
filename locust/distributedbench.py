import os
import csv
import json
import logging
from locust import task, between, events, FastHttpUser
from config import DEFAULT_SLA, DEFAULT_HEADERS

# 环境与配置
MIN_WAIT = float(os.getenv('LOCUST_MIN_WAIT', 1.0))
MAX_WAIT = float(os.getenv('LOCUST_MAX_WAIT', 2.0))
POST_PATH = os.getenv('POST_API_PATH')

# SLA 阈值（支持环境变量覆盖）
MAX_RT = int(os.getenv('MAX_AVERAGE_RESPONSE_TIME', DEFAULT_SLA['max_avg_rt']))
MAX_FAIL_RATE = float(os.getenv('MAX_FAILURE_RATE', DEFAULT_SLA['max_fail_rate']))
MAX_P99_RT = int(os.getenv('MAX_P99_RESPONSE_TIME', DEFAULT_SLA['max_p99_rt']))

# User-Agent 配置（支持环境变量自定义）
USER_AGENT = os.getenv('LOCUST_USER_AGENT', DEFAULT_HEADERS['User-Agent'])

logging.basicConfig(level=logging.INFO)

class WebsiteUser(FastHttpUser):
    # 动态等待时间
    wait_time = between(MIN_WAIT, MAX_WAIT)
    
    # 设置 User-Agent
    host = ""
    
    user_data_list = []

    def on_start(self):
        """数据驱动加载"""
        if not WebsiteUser.user_data_list and os.path.exists("users.csv"):
            try:
                with open("users.csv", mode='r', encoding='utf-8') as f:
                    WebsiteUser.user_data_list = list(csv.DictReader(f))
                logging.info(f"Loaded {len(WebsiteUser.user_data_list)} rows from users.csv")
            except Exception as e:
                logging.error(f"Failed to load CSV: {e}")

        # 简单的凭据分配
        self.credential = WebsiteUser.user_data_list.pop(0) if WebsiteUser.user_data_list else {}
        
        # 设置客户端 User-Agent
        if hasattr(self.client, 'headers'):
            self.client.headers["User-Agent"] = USER_AGENT

    @task(3)
    def index(self):
        """基础 GET 请求"""
        self.client.get("/", name="首页")

    @task(1)
    def complex_scenario(self):
        """复杂场景支持"""
        if POST_PATH:
            payload = json.loads(os.getenv('POST_PAYLOAD', '{}'))
            payload.update(self.credential)
            self.client.post(POST_PATH, json=payload, name=f"Scenario:{POST_PATH}")

@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    """SLA 熔断逻辑检查"""
    if hasattr(environment.stats, 'total'):
        total = environment.stats.total
        avg_rt = total.avg_response_time
        fail_rate = (total.num_failures / total.num_requests * 100) if total.num_requests > 0 else 0
        
        # 获取 P99 响应时间
        p99_rt = total.get_response_time_percentile(0.99) if hasattr(total, 'get_response_time_percentile') else 0

        logging.info(f"Final Stats - Avg RT: {avg_rt:.2f}ms, P99 RT: {p99_rt:.2f}ms, Fail Rate: {fail_rate:.2f}%")

        breached = False
        reasons = []

        if avg_rt > MAX_RT:
            breached = True
            reasons.append(f"Average Response Time ({avg_rt:.2f}ms) > Threshold ({MAX_RT}ms)")

        if fail_rate > MAX_FAIL_RATE:
            breached = True
            reasons.append(f"Failure Rate ({fail_rate:.2f}%) > Threshold ({MAX_FAIL_RATE}%)")
            
        if p99_rt > MAX_P99_RT:
            breached = True
            reasons.append(f"P99 Response Time ({p99_rt:.2f}ms) > Threshold ({MAX_P99_RT}ms)")

        if breached:
            logging.warning(f"SLA BREACHED: {', '.join(reasons)}")
            # 写入熔断标记文件
            with open(".bench_threshold_reached", "w") as f:
                f.write(f"breached: {'; '.join(reasons)}")
