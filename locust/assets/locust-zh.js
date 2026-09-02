// Locust 报告汉化脚本 - 前端动态翻译版本
// 此脚本在浏览器端运行，动态翻译 Locust 报告的 UI 文本

(function() {
    'use strict';

    // 当前语言状态
    let currentLanguage = 'zh'; // 'zh' 或 'en'

    // 翻译字典（按字符串长度降序排列，确保长字符串优先匹配）
    const TRANSLATIONS = {
        "Response Time Statistics": "响应时间统计",
        "Exceptions Statistics": "异常明细统计",
        "Request Statistics": "请求统计详情",
        "Failures Statistics": "失败明细统计",
        "Tasks Statistics": "任务分布统计",
        "Locust Test Report": "Locust 性能压测报告",
        "Current Requests per Second": "当前请求/秒",
        "Current Failure per Second": "当前失败/秒",
        "Average Response Time": "平均响应时间",
        "Median Response Time": "响应时间中位数",
        "Min Response Time": "最小响应时间",
        "Max Response Time": "最大响应时间",
        "Average Content Size": "平均内容大小",
        "Requests per Second": "每秒请求数(RPS)",
        "Failures per Second": "每秒失败数",
        "Number of Requests": "请求数",
        "Number of Users": "并发用户数",
        "Average Size (bytes)": "平均大小(字节)",
        "Ratio Per Class": "按类别占比",
        "Tasks distribution": "任务分布",
        "Final ratio": "最终任务权重",
        "Response Time (ms)": "响应时间(毫秒)",
        "Average (ms)": "平均值",
        "Median (ms)": "中位数",
        "Total Requests": "总请求数",
        "Total Failures": "总失败数",
        "Total Ratio": "总占比",
        "Charts and graphs": "图表和图形",
        "Response Times": "响应时间趋势",
        "Content size": "内容大小",
        "Response time": "响应时间",
        "Per Type": "按类型",
        "Per Name": "按名称",
        "Distribution": "分布",
        "Occurrences": "出现次数",
        "Target Host:": "目标主机：",
        "During:": "测试时间：",
        "Script:": "脚本：",
        "Elapsed time": "持续时间",
        "Start time": "开始时间",
        "Stop time": "结束时间",
        "Exception": "异常",
        "Statistics": "统计详情",
        "Failures": "失败明细",
        "Exceptions": "异常明细",
        "Download CSV": "下载CSV",
        "Download HTML": "下载HTML",
        "Export Data": "导出数据",
        "Download Data": "下载数据",
        "WebsiteUser": "虚拟用户类",
        "Swarming": "压测中",
        "complexScenario": "复杂业务场景",
        "Hatching": "启动中",
        "Running": "运行中",
        "Stopped": "已停止",
        "Quitting": "退出中",
        "Aggregated": "汇总",
        "Spawn rate": "启动速率",
        "Failure Ratio": "失败率",
        "Requests/s": "请求/秒",
        "Failures/s": "失败/秒",
        "Target Host": "目标主机",
        "Test Report": "压测报告",
        "Run time": "运行时间",
        "Tasks": "任务分布",
        "Ratio": "占比",
        "Traceback": "堆栈",
        "Charts": "图表",
        "Status": "状态",
        "Method": "方法",
        "Message": "错误信息",
        "# Fails": "# 失败数",
        "Average Size": "平均大小",
        "Seconds": "秒",
        "seconds": "秒",
        "Test statistics": "测试统计",
        "Req/s": "请求/秒",
        "Fails": "失败数",
        "Requests": "请求数",
        "Max (ms)": "最大值",
        "Min (ms)": "最小值",
        "Average": "平均值",
        "Median": "中位数",
        "Second": "秒",
        "second": "秒",
        "Total": "总数",
        "RPS": "请求/秒",
        "Type": "类型",
        "Name": "名称",
        "Max": "最大值",
        "Min": "最小值",
        "ms": "毫秒",
        "ile": "位",
        "and": "和"
    };

    // 创建文本节点遍历器
    function getTextNodes(node) {
        const textNodes = [];
        const walker = document.createTreeWalker(
            node,
            NodeFilter.SHOW_TEXT,
            {
                acceptNode: function(textNode) {
                    // 跳过 script 和 style 标签内的文本
                    if (textNode.parentNode.tagName === 'SCRIPT' || 
                        textNode.parentNode.tagName === 'STYLE') {
                        return NodeFilter.FILTER_REJECT;
                    }
                    // 只处理非空的文本节点
                    if (textNode.textContent.trim() === '') {
                        return NodeFilter.FILTER_REJECT;
                    }
                    return NodeFilter.FILTER_ACCEPT;
                }
            }
        );

        let currentNode;
        while (currentNode = walker.nextNode()) {
            textNodes.push(currentNode);
        }
        return textNodes;
    }

    // 翻译文本节点
    function translateTextNodes() {
        const textNodes = getTextNodes(document.body);
        let translatedCount = 0;

        textNodes.forEach(textNode => {
            const originalText = textNode.textContent.trim();
            let newText = originalText;
            
            // 根据当前语言状态决定是翻译还是恢复
            if (currentLanguage === 'zh') {
                // 翻译成中文
                for (const [enText, zhText] of Object.entries(TRANSLATIONS)) {
                    if (newText === enText) {
                        newText = zhText;
                        translatedCount++;
                        break;
                    }
                    // 处理包含英文的文本
                    else if (newText.includes(enText)) {
                        newText = newText.replace(enText, zhText);
                        translatedCount++;
                    }
                }
                
                // 特殊处理：翻译 (ms) 为 (毫秒)
                if (newText.includes('(ms)')) {
                    newText = newText.replace('(ms)', '(毫秒)');
                    translatedCount++;
                }
            } else {
                // 恢复成英文
                for (const [enText, zhText] of Object.entries(TRANSLATIONS)) {
                    if (newText === zhText) {
                        newText = enText;
                        translatedCount++;
                        break;
                    }
                    // 处理包含中文的文本
                    else if (newText.includes(zhText)) {
                        newText = newText.replace(zhText, enText);
                        translatedCount++;
                    }
                }
                
                // 特殊处理：恢复 (毫秒) 为 (ms)
                if (newText.includes('(毫秒)')) {
                    newText = newText.replace('(毫秒)', '(ms)');
                    translatedCount++;
                }
            }
            
            // 只有当文本真正改变时才更新
            if (newText !== originalText) {
                textNode.textContent = newText;
            }
        });

        return translatedCount;
    }

    // 观察器，用于动态加载的内容
    function setupObserver() {
        const observer = new MutationObserver(function(mutations) {
            mutations.forEach(function(mutation) {
                mutation.addedNodes.forEach(function(node) {
                    if (node.nodeType === Node.ELEMENT_NODE) {
                        // 延迟翻译，确保 React 渲染完成
                        setTimeout(() => {
                            translateTextNodes();
                        }, 100);
                    }
                });
            });
        });

        observer.observe(document.body, {
            childList: true,
            subtree: true
        });

        return observer;
    }

    // 添加语言切换按钮
    function addLanguageToggleButton() {
        // 检查是否已经添加过按钮
        if (document.getElementById('lang-toggle-btn')) {
            return;
        }

        const btn = document.createElement('button');
        btn.id = 'lang-toggle-btn';
        btn.textContent = 'English';
        btn.style.cssText = `
            position: fixed;
            top: 10px;
            right: 10px;
            z-index: 10000;
            padding: 8px 16px;
            background: #fff;
            border: 1px solid #ccc;
            border-radius: 4px;
            cursor: pointer;
            font-size: 14px;
            font-weight: bold;
            color: #333;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            transition: all 0.3s;
        `;
        
        btn.onmouseover = function() {
            this.style.background = '#f5f5f5';
        };
        
        btn.onmouseout = function() {
            this.style.background = '#fff';
        };

        btn.onclick = function() {
            toggleLanguage();
        };

        document.body.appendChild(btn);
    }

    // 切换语言
    function toggleLanguage() {
        const btn = document.getElementById('lang-toggle-btn');
        if (currentLanguage === 'zh') {
            currentLanguage = 'en';
            if (btn) btn.textContent = '中文';
            console.log('切换到英文');
        } else {
            currentLanguage = 'zh';
            if (btn) btn.textContent = 'English';
            console.log('切换到中文');
        }
        translateTextNodes();
    }

    // 隐藏 Script 信息
    function hideScriptInfo() {
        // 等待页面加载完成
        setTimeout(() => {
            // 查找包含 "Script:" 的元素
            const allTextNodes = getTextNodes(document.body);
            allTextNodes.forEach(node => {
                const text = node.textContent;
                if (text.includes('Script:') || text.includes('脚本：')) {
                    // 隐藏包含 Script 信息的行
                    const parent = node.parentElement;
                    if (parent) {
                        const grandparent = parent.parentElement;
                        if (grandparent) {
                            grandparent.style.display = 'none';
                        }
                    }
                }
            });
        }, 1000);
    }

    // 主函数
    function translateLocustReport() {
        console.log('开始翻译 Locust 报告...');
        
        // 添加语言切换按钮
        addLanguageToggleButton();
        
        // 隐藏 Script 信息
        hideScriptInfo();
        
        // 初始翻译
        const initialCount = translateTextNodes();
        console.log(`初始翻译完成，共翻译 ${initialCount} 处`);

        // 设置观察器，用于动态内容
        const observer = setupObserver();
        console.log('已设置动态内容观察器');

        // 定期检查并翻译（每秒一次，持续10秒）
        let checkCount = 0;
        const intervalId = setInterval(() => {
            const count = translateTextNodes();
            if (count > 0) {
                console.log(`检查 ${checkCount + 1}: 新翻译 ${count} 处`);
            }
            checkCount++;
            if (checkCount >= 10) {
                clearInterval(intervalId);
                console.log('翻译检查完成');
            }
        }, 1000);

        // 额外延迟翻译，确保 React 完全渲染
        setTimeout(() => {
            const delayedCount = translateTextNodes();
            console.log(`延迟翻译完成，共翻译 ${delayedCount} 处`);
        }, 2000);

        setTimeout(() => {
            const delayedCount = translateTextNodes();
            console.log(`再次延迟翻译完成，共翻译 ${delayedCount} 处`);
        }, 5000);
    }

    // 等待页面加载完成后执行翻译
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', translateLocustReport);
    } else {
        // 如果页面已经加载，等待 React 渲染完成
        setTimeout(translateLocustReport, 500);
    }

    // 将翻译函数暴露到全局，以便手动调用
    window.translateLocustReport = translateLocustReport;
})();