# Selenium 自动化测试

> Web 自动化测试工具

## 📋 目录说明

| 脚本文件 | 说明 | 版本检测 | 帮助函数 |
|---------|------|---------|---------|
| `selenium_utils.py` | Selenium 工具库 | ❌ | ❌ |

## 🚀 快速开始

### 使用 Selenium 工具

```bash
cd selenium
python3 selenium_utils.py
```

## 🔧 详细说明

### selenium_utils.py - Selenium 工具库

**功能**: Selenium WebDriver 工具库

**支持浏览器**:
- Chrome
- Firefox
- Safari
- Edge

**常用功能**:
- 元素定位
- 页面操作
- 表单填写
- 截图功能
- 等待机制

**Python 示例**:
```python
from selenium import webdriver

# 初始化浏览器
driver = webdriver.Chrome()

# 打开网页
driver.get("https://example.com")

# 查找元素
element = driver.find_element_by_id("username")

# 操作元素
element.send_keys("test_user")

# 截图
driver.save_screenshot("screenshot.png")

# 关闭浏览器
driver.quit()
```

## 🔗 相关链接

- [Selenium 官方网站](https://www.selenium.dev/)
- [Selenium 文档](https://www.selenium.dev/documentation/)

## 📝 使用场景

- **UI 自动化测试**: Web 应用 UI 自动化测试
- **功能测试**: 业务功能自动化验证
- **回归测试**: 自动化回归测试
- **爬虫开发**: 网页数据抓取