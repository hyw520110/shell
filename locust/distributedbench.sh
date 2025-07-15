#!/bin/bash

# 确保脚本运行时的语言环境为中文
export LANG="zh_CN.UTF-8"
export LC_ALL="zh_CN.UTF-8"

# 推荐python版本
PYTHON_VERSION="3.9.7"
# python最低版本
MIN_PYTHON_VERSION="3.7.0"
# 虚拟环境名
VENV_NAME="locust-env"
# 默认测试目标
DEFAULT_HOST="https://www.baidu.com"
# 默认总用户数
DEFAULT_USERS=100
DEFAULT_SPAWN_RATE=100
# 默认持续时间
DEFAULT_RUN_TIME="15m"  
# 默认报告保存目录
DEFAULT_REPORT_DIR="$(pwd)/report"
# 分布式测试master
MASTER_HOST="localhost"
# 持续迭代步长，默认不迭代
DEFAULT_STEP=0  
# 最大平均响应时间 (ms)
MAX_AVERAGE_RESPONSE_TIME=2000  
 # 最大错误率 (5%)
MAX_ERROR_RATE=0.05      

# 设置颜色变量用于美化输出
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# 函数用于比较两个 Python 版本号
python_version_compare() {
    [[ "$1" == "$(echo -e "$1\n$2" | sort -V | tail -n1)" ]]
}
 
# 检测并安装 pyenv 和 pyenv-virtualenv
install_pyenv_and_virtualenv() {
    if ! command -v pyenv &> /dev/null; then
        echo -e "${RED}未找到pyenv。正在安装...${NC}"
        curl https://pyenv.run | bash > /dev/null 2>&1
        export PATH="$HOME/.pyenv/bin:$PATH"
        eval "$(pyenv init --path)"
        eval "$(pyenv init -)"
    fi

    VIRTUAL_ENV_ENABLED=false
    if [ ! -d "$(pyenv root)/plugins/pyenv-virtualenv" ]; then
        echo -e "${GREEN}尝试安装pyenv-virtualenv...${NC}"
        if git clone https://github.com/pyenv/pyenv-virtualenv.git $(pyenv root)/plugins/pyenv-virtualenv > /dev/null 2>&1; then
            VIRTUAL_ENV_ENABLED=true
            eval "$(pyenv virtualenv-init -)"
            echo -e "${GREEN}pyenv-virtualenv安装成功。${NC}"
        else
            echo -e "${RED}pyenv-virtualenv安装失败。继续不使用虚拟环境。${NC}"
        fi
    else
        VIRTUAL_ENV_ENABLED=true
        eval "$(pyenv virtualenv-init -)"
    fi
    eval "$(pyenv init -)"
}

# 确保合适的Python版本已安装
ensure_python_installed() {
    INSTALLED_VERSIONS=$(pyenv versions --bare)
    HIGHEST_INSTALLED_VERSION=$(echo "$INSTALLED_VERSIONS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | head -n 1)

    if [[ -z "$HIGHEST_INSTALLED_VERSION" ]] || ! python_version_compare "$HIGHEST_INSTALLED_VERSION" "$MIN_PYTHON_VERSION"; then
        echo -e "${RED}未找到合适版本的Python。正在安装Python $PYTHON_VERSION...${NC}"
        pyenv install -s $PYTHON_VERSION > /dev/null 2>&1
        pyenv global $PYTHON_VERSION
    else
        echo -e "${GREEN}Python版本: $HIGHEST_INSTALLED_VERSION${NC}"
        pyenv global $HIGHEST_INSTALLED_VERSION
    fi
}

# 创建并激活虚拟环境
create_and_activate_venv() {
    if $VIRTUAL_ENV_ENABLED && [ ! -d "$HOME/.pyenv/versions/$VENV_NAME" ]; then
        echo -e "${GREEN}创建虚拟环境 $VENV_NAME...${NC}"
        pyenv virtualenv $(pyenv global) $VENV_NAME > /dev/null 2>&1
    fi
    pyenv activate $VENV_NAME
    python -m pip install --upgrade pip > /dev/null 2>&1
}
# 安装 Locust 及其依赖
install_locust() {

    # 使用 pip show 检查 Locust 是否已安装
    if ! pip show locust &>/dev/null; then
        echo -e "${RED}未找到Locust。正在安装...${NC}"
        if pip install --quiet locust pandas beautifulsoup4 lxml; then
            echo -e "${GREEN}Locust安装完成。${NC}"
        else
            echo -e "${RED}Locust安装失败。${NC}"
            return 1
        fi
    fi
}

# 获取用户输入
get_user_input() {
    read -p "输入测试网址 (默认: $DEFAULT_HOST): " HOST
    HOST=${HOST:-$DEFAULT_HOST}

    read -p "输入总用户数 (默认: $DEFAULT_USERS): " USERS
    USERS=${USERS:-$DEFAULT_USERS}

    read -p "输入每秒启动的新用户数 (默认: $DEFAULT_SPAWN_RATE): " SPAWN_RATE
    SPAWN_RATE=${SPAWN_RATE:-$DEFAULT_SPAWN_RATE}

    read -p "输入测试持续时长（格式：1m, 15m, 1h, 一般15m或30m） (默认: $DEFAULT_RUN_TIME): " RUN_TIME
    RUN_TIME=${RUN_TIME:-$DEFAULT_RUN_TIME}

    # 输入的持续时长兼容不带时间单位，默认为分
    if [[ "$RUN_TIME" =~ ^[0-9]+$ ]]; then
        RUN_TIME="${RUN_TIME}m"
    fi

    read -p "输入总用户数迭代步长 (0表示不迭代，默认: $DEFAULT_STEP): " STEP
    STEP=${STEP:-$DEFAULT_STEP}
    read -p "输入报告保存的目录 (默认: $DEFAULT_REPORT_DIR): " REPORT_DIR
    REPORT_DIR=${REPORT_DIR:-$DEFAULT_REPORT_DIR}
    [ ! -d $REPORT_DIR ] && mkdir -p $REPORT_DIR
   
}


# 动态获取测试路径
get_additional_paths() {
    ADDITIONAL_PATHS=""
    
    # 自动探测路径
    auto_detect_paths() {
        echo -e "${GREEN}正在探测目标网站的路径，请稍候...${NC}"
        
        # 检测是否安装了selenium
        if python -c "import selenium" &> /dev/null; then
            echo -e "${GREEN}selenium路径探测...${NC}"
            
            # 使用selenium模拟浏览器行为
            DETECTED_PATHS=$(python -c "
from selenium import webdriver
from selenium.webdriver.chrome.options import Options

chrome_options = Options()
chrome_options.add_argument('--headless')
driver = webdriver.Chrome(options=chrome_options)
driver.get('$HOST')
dynamic_paths = [elem.get_attribute('href') for elem in driver.find_elements_by_tag_name('a') if elem.get_attribute('href').startswith('/') and '?' not in elem.get_attribute('href') and '#' not in elem.get_attribute('href')]
driver.quit()
print(';'.join(dynamic_paths))
")
        else
            echo -e "${GREEN}BeautifulSoup路径探测...${NC}"
            
            # 使用BeautifulSoup解析HTML并提取路径
            DETECTED_PATHS=$(python -c "
import requests
from bs4 import BeautifulSoup

response = requests.get('$HOST')
soup = BeautifulSoup(response.text, 'html.parser')
paths = []

# 提取所有<a>标签中的href属性
for link in soup.find_all('a', href=True):
    href = link['href']
    if href.startswith('/') and '?' not in href and '#' not in href:
        paths.append(href)

print(';'.join(paths))
")
        fi

        if [[ -z "$DETECTED_PATHS" ]]; then
            echo -e "${RED}未能探测到任何路径，请手动输入。${NC}"
            return 1
        fi

        # 显示探测到的路径列表
        echo -e "${GREEN}探测到以下路径：${NC}"
        PATH_LIST=()
        INDEX=1
        for path in $DETECTED_PATHS; do
            PATH_LIST+=("$path")
            echo "[$INDEX] $path"
            ((INDEX++))
        done

        # 用户选择路径
        while true; do
            read -p "请选择路径编号（多个用逗号分隔，输入 'all' 选择所有路径，按 Enter 跳过）: " selection
            if [[ -z "$selection" ]]; then
                break
            elif [[ "$selection" == "all" ]]; then
                for path in "${PATH_LIST[@]}"; do
                    ADDITIONAL_PATHS+="$path,自动探测;"
                done
                echo -e "${GREEN}已选择所有路径。${NC}"
                break
            else
                IFS=',' read -ra selections <<< "$selection"
                for idx in "${selections[@]}"; do
                    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#PATH_LIST[@]} )); then
                        selected_path="${PATH_LIST[$((idx-1))]}"
                        ADDITIONAL_PATHS+="$selected_path,自动探测;"
                    else
                        echo -e "${RED}无效的选择: $idx，请重新输入。${NC}"
                    fi
                done
                break
            fi
        done
    }

    # 手动输入路径
    manual_input_paths() {
        while true; do
            read -p "默认首页，输入其他路由路径 (例如: /about,关于我们) 或按 Enter 结束: " path_input
            if [[ -z "$path_input" ]]; then
                break
            elif [[ "$path_input" =~ ^/.+,.+$ ]]; then
                ADDITIONAL_PATHS+="${path_input};"
            else
                echo -e "${RED}路径格式错误，应为 '/path,描述'。${NC}"
            fi
        done
    }

    while true; do
        read -p "是否自动探测路径？(y/n，默认: y): " AUTO_DETECT
        AUTO_DETECT=${AUTO_DETECT:-y}
        if [[ "$AUTO_DETECT" == "y" ]]; then
            if ! auto_detect_paths; then
                manual_input_paths
            fi
            break
        elif [[ "$AUTO_DETECT" == "n" ]]; then
            manual_input_paths
            break
        else
            echo -e "${RED}无效输入，请输入 'y' 或 'n'。${NC}"
        fi
    done

    export LOCUST_ADDITIONAL_PATHS=$ADDITIONAL_PATHS
}

# 提示用户是否启用分布式测试
ask_for_distributed_test() {
    read -p "是否启用分布式测试？(y/n，默认: n): " DISTRIBUTED
    DISTRIBUTED=${DISTRIBUTED:-n}
}

# 获取当前主机IP
get_current_host_ip() {
    CURRENT_HOST_IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}当前主机IP: $CURRENT_HOST_IP${NC}"
}

# 添加函数：将运行时间转换为秒数
convert_run_time_to_seconds() {
    local run_time=$1
    local duration
    case ${run_time: -1} in
        m) duration=$((10#${run_time::-1} * 60));;  # 分钟转秒
        h) duration=$((10#${run_time::-1} * 3600));; # 小时转秒
        s) duration=$((10#${run_time::-1}));;       # 秒转秒
        *) duration=$run_time;;                     # 默认为秒
    esac
    echo $duration
}

# 启动 Locust 测试
run_locust_test() {
    START_TIME=$(date +%s)
    MAX_DURATION=$(($(date +%s) + $(convert_run_time_to_seconds $RUN_TIME)))

    CURRENT_USERS=$USERS
    ITERATION=1

    while true; do
        TIMESTAMP=$(date +"%Y%m%d%H%M%S")
        DOMAIN=$(echo $HOST | awk -F[/:] '{print $4}')
        # 修改文件名格式，将迭代次数和时间戳移到文件后缀前面
        REPORT_FILE="$REPORT_DIR/${DOMAIN}_报告${ITERATION}_${TIMESTAMP}.html"

        COMMON_ARGS=(
            "-f" "distributedbench.py" 
            "--host=$HOST"
            "--headless"
            "-u" "$CURRENT_USERS"
            "-r" "$SPAWN_RATE"
            "--run-time" "$RUN_TIME"
            "--html" "$REPORT_FILE"
            "--csv" "$REPORT_DIR/${DOMAIN}_报告${ITERATION}_${TIMESTAMP}"
        )

        # 确保 Locust 运行时的语言环境为中文
        export LANG="zh_CN.UTF-8"
        export LC_ALL="zh_CN.UTF-8"

        if [[ "$DISTRIBUTED" == "y" ]]; then
            # 获取当前主机IP
            get_current_host_ip
            
            # 如果用户未输入master节点IP，则默认使用当前主机IP
            read -p "请输入master节点的IP地址（默认: $CURRENT_HOST_IP）: " MASTER_HOST
            MASTER_HOST=${MASTER_HOST:-$CURRENT_HOST_IP}
            
            read -p "此节点是 master 还是 worker？(m/w，默认: m): " NODE_TYPE
            NODE_TYPE=${NODE_TYPE:-m}
            
            if [[ "$NODE_TYPE" == "m" ]]; then
                echo -e "${GREEN}启动Locust master节点...${NC}"
                locust "${COMMON_ARGS[@]}" --master &
            elif [[ "$NODE_TYPE" == "w" ]]; then
                # 如果worker节点不是当前主机，则通过SSH传输脚本并执行
                if [[ "$MASTER_HOST" != "$CURRENT_HOST_IP" ]]; then
                    read -p "请输入远程主机的用户名: " REMOTE_USER
                    read -s -p "请输入远程主机的密码: " REMOTE_PASSWORD
                    echo
                    
                    # 使用SSH传输脚本并执行
                    sshpass -p "$REMOTE_PASSWORD" scp distributedbench.sh "$REMOTE_USER@$MASTER_HOST:/tmp/"
                    sshpass -p "$REMOTE_PASSWORD" ssh "$REMOTE_USER@$MASTER_HOST" "bash /tmp/distributedbench.sh"
                    exit 0  # 工作节点不需要继续执行后续逻辑
                else
                    echo -e "${GREEN}启动Locust worker节点...${NC}"
                    locust --worker --master-host=$MASTER_HOST
                    exit 0  # 工作节点不需要继续执行后续逻辑
                fi
            else
                echo -e "${RED}无效的节点类型，必须是 'm' 或 'w'. 使用默认值 'm'.${NC}"
                locust "${COMMON_ARGS[@]}" --master &
            fi
        else
            echo -e "${GREEN}启动单节点Locust测试...${NC}"
            locust "${COMMON_ARGS[@]}" &
        fi

        PID=$!
        wait $PID 2>/dev/null

        END_TIME=$(date +%s)
        ELAPSED_TIME=$((END_TIME - START_TIME))

        if [[ $? -eq 0 ]] && ((ELAPSED_TIME < MAX_DURATION)); then
            echo -e "${GREEN}测试成功，可以继续增加用户数。${NC}"
            if ((STEP > 0)); then
                CURRENT_USERS=$((CURRENT_USERS * STEP))
                ITERATION=$((ITERATION + 1))
            else
                echo -e "${GREEN}不进行迭代，测试结束。${NC}"
                break
            fi
        else
            echo -e "${RED}测试未能继续或已达到最大持续时间，停止增加用户数。${NC}"
            break
        fi

        echo -e "${GREEN}测试完成，报告已保存至 $REPORT_FILE${NC}"
        
        # 如果剩余时间不足以完成一次新的测试，则退出
        REMAINING_TIME=$((MAX_DURATION - $(date +%s)))
        if ((REMAINING_TIME < $(convert_run_time_to_seconds $RUN_TIME))); then
            echo -e "${RED}剩余时间不足以完成新的测试，停止迭代。${NC}"
            break
        fi
    done
    # 调用翻译脚本
    python3 translate_report.py

}

webtest() {
    install_pyenv_and_virtualenv
    ensure_python_installed
    create_and_activate_venv
    install_locust
    get_user_input
    get_additional_paths
    ask_for_distributed_test
    run_locust_test
}

webtest