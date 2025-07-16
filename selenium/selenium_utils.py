import os
import logging
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from webdriver_manager.chrome import ChromeDriverManager

def fetch_dynamic_html(source):
    """
    获取动态渲染的 HTML 内容

    :param source: HTML 文件路径或 URL
    :return: 动态渲染后的 HTML 内容
    """
    try:
        # 初始化浏览器驱动
        driver = _init_driver()
        
        # 判断 source 是 URL 还是本地路径
        if source.startswith("http"):
            driver.get(source)
        else:
            driver.get(f"file://{os.path.abspath(source)}")
            
        # 等待页面上的任意元素渲染完成
        _wait_for_element_render(driver, (By.XPATH, "//body"))
        
        # 获取完整的 HTML 源码
        html_content = driver.page_source
        driver.quit()
        return html_content
    except Exception as e:
        logging.error(f"获取动态 HTML 失败: {str(e)}")
        return None

def _init_driver(chrome_driver_path=None):
    """
    初始化 Selenium 浏览器驱动
    :param chrome_driver_path: 指定的 ChromeDriver 路径（可选）
    """
    if chrome_driver_path and os.path.exists(chrome_driver_path):
        logging.info(f"使用指定的 ChromeDriver 路径: {chrome_driver_path}")
    else:
        chrome_driver_path = ChromeDriverManager().install()
        logging.info(f"自动安装 ChromeDriver 成功，路径为: {chrome_driver_path}")
    
    service = Service(executable_path=chrome_driver_path)
    chrome_options = Options()
    chrome_options.add_argument("--headless")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--disable-dev-shm-usage")
    driver = webdriver.Chrome(service=service, options=chrome_options)
    browser_version = driver.capabilities['browserVersion']
    logging.info(f"当前浏览器版本: {browser_version}")
    return driver

def _wait_for_element_render(driver, locator):
    """
    等待指定元素渲染完成

    :param driver: Selenium WebDriver 实例
    :param locator: 元素定位器，例如 (By.XPATH, "//div[@class='example']")
    """
    WebDriverWait(driver, 10).until(
        EC.presence_of_element_located(locator)
    )
