#!/bin/bash

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
        echo -e "${GREEN}pyenv-virtualenv已安装。${NC}"
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
        echo -e "${GREEN}使用已有的Python版本: $HIGHEST_INSTALLED_VERSION${NC}"
        pyenv global $HIGHEST_INSTALLED_VERSION
    fi
}

# 创建并激活虚拟环境
create_and_activate_venv() {
    if $VIRTUAL_ENV_ENABLED && [ ! -d "$HOME/.pyenv/versions/$VENV_NAME" ]; then
        echo -e "${GREEN}创建虚拟环境 $VENV_NAME...${NC}"
        pyenv virtualenv $(pyenv global) $VENV_NAME > /dev/null 2>&1
    fi
    echo "激活虚拟环境$VENV_NAME"
    pyenv activate $VENV_NAME
    python -m pip install --upgrade pip > /dev/null 2>&1
}
# 安装 Locust 及其依赖
install_locust() {
    echo -e "${GREEN}检查 Locust 是否已安装...${NC}"

    # 使用 pip show 检查 Locust 是否已安装
    if pip show locust &>/dev/null; then
        echo -e "${GREEN}Locust已安装。${NC}"
    else
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
    read -p "请输入需测试的Web系统网址 (默认: $DEFAULT_HOST): " HOST
    HOST=${HOST:-$DEFAULT_HOST}

    read -p "请输入总用户数 (默认: $DEFAULT_USERS): " USERS
    USERS=${USERS:-$DEFAULT_USERS}

    read -p "请输入每秒启动的新用户数 (默认: $DEFAULT_SPAWN_RATE): " SPAWN_RATE
    SPAWN_RATE=${SPAWN_RATE:-$DEFAULT_SPAWN_RATE}

    read -p "请输入测试持续时长（格式：1m, 15m, 1h,一般15m或30m） (默认: $DEFAULT_RUN_TIME): " RUN_TIME
    RUN_TIME=${RUN_TIME:-$DEFAULT_RUN_TIME}
 	read -p "请输入总用户数迭代步长 (0表示不迭代，默认: $DEFAULT_STEP): " STEP
    STEP=${STEP:-$DEFAULT_STEP}
    read -p "请输入报告保存的目录 (默认: $DEFAULT_REPORT_DIR): " REPORT_DIR
    REPORT_DIR=${REPORT_DIR:-$DEFAULT_REPORT_DIR}
	[ ! -d $REPORT_DIR ] && mkdir -p $REPORT_DIR
   
}


# 动态获取测试路径
get_additional_paths() {
    ADDITIONAL_PATHS=""
    while true; do
        read -p "默认首页，输入其他路由路径 (例如: /about,关于我们) 或按 Enter 结束: " path_input
        if [[ -z "$path_input" ]]; then
            break
        fi
        ADDITIONAL_PATHS+="${path_input};"
    done
    export LOCUST_ADDITIONAL_PATHS=$ADDITIONAL_PATHS
}

# 提示用户是否启用分布式测试
ask_for_distributed_test() {
    read -p "是否启用分布式测试？(y/n，默认: n): " DISTRIBUTED
    DISTRIBUTED=${DISTRIBUTED:-n}
}
   
# 将运行时间转换为秒数
convert_run_time_to_seconds() {
    local run_time=$1
    case $run_time in
        *m) echo $(( ${run_time%m} * 60 ));;
        *h) echo $(( ${run_time%h} * 3600 ));;
        *) echo $(( ${run_time%s} ));;
    esac
}

# 启动 Locust 测试
run_locust_test() {
    START_TIME=$(date +%s)
    MAX_DURATION=$(($(date +%s) + $(convert_run_time_to_seconds $RUN_TIME)))

    CURRENT_USERS=$USERS
    ITERATION=1

    while true; do
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        DOMAIN=$(echo $HOST | awk -F[/:] '{print $4}')
        REPORT_FILE="$REPORT_DIR/${DOMAIN}_report_iter${ITERATION}_${TIMESTAMP}.html"

        COMMON_ARGS=(
            "-f" "distributedbench.py" 
            "--host=$HOST"
            "--headless"
            "-u" "$CURRENT_USERS"
            "-r" "$SPAWN_RATE"
            "--run-time" "$RUN_TIME"
            "--html" "$REPORT_FILE"
            "--csv" "$REPORT_DIR/${DOMAIN}_report_iter${ITERATION}_${TIMESTAMP}"
        )

        if [[ "$DISTRIBUTED" == "y" ]]; then
            read -p "请输入master节点的IP地址（默认: $MASTER_HOST）: " MASTER_HOST
            MASTER_HOST=${MASTER_HOST:-$MASTER_HOST}
            
            read -p "此节点是 master 还是 worker？(m/w，默认: m): " NODE_TYPE
            NODE_TYPE=${NODE_TYPE:-m}
            
            if [[ "$NODE_TYPE" == "m" ]]; then
                echo -e "${GREEN}启动Locust master节点...${NC}"
                locust "${COMMON_ARGS[@]}" --master &
            elif [[ "$NODE_TYPE" == "w" ]]; then
                echo -e "${GREEN}启动Locust worker节点...${NC}"
                locust --worker --master-host=$MASTER_HOST
                exit 0  # 工作节点不需要继续执行后续逻辑
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


