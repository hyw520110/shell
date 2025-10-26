#!/bin/bash
# skywalking自动安装、配置

# 定义日志函数
log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1" >&2
}

log_error() {
  echo "[ERROR] $1" >&2
}

# 定义变量
TMP_DIR=/tmp
APP_BASE_DIR=/opt/apps
SW_HOME=/opt/skywalking
SW_VERSION=10.2.0
SW_URL=https://archive.apache.org/dist/skywalking/$SW_VERSION/apache-skywalking-apm-$SW_VERSION.tgz
SW_TGZ=$TMP_DIR/apache-skywalking-apm-$SW_VERSION.tgz

# SkyWalking agent配置
SKYWALKING_AGENT_BASE_DIR="$SW_HOME/skywalking-agent"
SKYWALKING_AGENT_VERSION="9.4.0"
SKYWALKING_AGENT_DOWNLOAD_URL="https://archive.apache.org/dist/skywalking/java-agent/9.4.0/apache-skywalking-java-agent-9.4.0.tgz"
SKYWALKING_AGENT_TGZ="$TMP_DIR/apache-skywalking-java-agent-${SKYWALKING_AGENT_VERSION}.tgz"

# 检查操作系统
function check_os () {
  if [ -f /etc/redhat-release ]; then
    OS="CentOS"
  elif [ -f /etc/debian_version ]; then
    OS="Deepin"
  elif [ "$(uname -s)" = "Darwin" ]; then
    OS="Darwin"
  else
    echo "不支持的操作系统"
    exit 1
  fi
}

# 下载 SkyWalking
function download_sw () {
  if [ ! -d ${SW_TGZ%/*} ]; then
    echo "mkdir -p ${SW_TGZ%/*}"
    mkdir -p ${SW_TGZ%/*}
  fi
  if [ ! -f $SW_TGZ ]; then
    echo "下载SkyWalking..."
    wget $SW_URL -O $SW_TGZ
  fi
}

# 解压 SkyWalking
function extract_sw () {
  if [ ! -d $SW_HOME ]; then
    mkdir -p $SW_HOME
  fi
  
  # 检查是否已经解压
  if [ ! -d "$SW_HOME/bin" ]; then
    echo "解压 SkyWalking..."
    tar -zxvf $SW_TGZ -C $SW_HOME --strip-components=1
    
    # 确保bin目录存在
    if [ ! -d "$SW_HOME/bin" ]; then
      log_error "解压失败，未找到bin目录"
      exit 1
    fi
  fi
}

# 配置 SkyWalking
function configure_sw () {
  # 创建 webapp 目录（如果不存在）
  mkdir -p $SW_HOME/webapp
  
  # 配置 collector
  collector_config=$SW_HOME/config/application.yml
  # 使用兼容的sed命令格式
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS需要额外参数
    sed -i "" 's/^collector.backend_service=.*/collector.backend_service=127.0.0.1:11800/' $collector_config
  else
    sed -i 's/^collector.backend_service=.*/collector.backend_service=127.0.0.1:11800/' $collector_config
  fi

  # 配置 UI
  ui_config=$SW_HOME/webapp/application.yml
  # 使用兼容的sed命令格式
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS需要额外参数
    sed -i "" 's/^server.port=.*/server.port=8080/' $ui_config
  else
    sed -i 's/^server.port=.*/server.port=8080/' $ui_config
  fi

  # 配置 agent
  agent_config=$SW_HOME/agent/config/agent.config
  if [ -f "$agent_config" ]; then
    # 使用兼容的sed命令格式
    if [[ "$(uname -s)" == "Darwin" ]]; then
      # macOS需要额外参数
      sed -i "" 's/^collector.backend_service=.*/collector.backend_service=127.0.0.1:11800/' $agent_config
    else
      sed -i 's/^collector.backend_service=.*/collector.backend_service=127.0.0.1:11800/' $agent_config
    fi
  fi
}

# 自动检测安装SkyWalking Agent
configure_skywalking_agent() {
    # 检查skywalking-agent目录是否存在且非空
    if [ -d "$SKYWALKING_AGENT_BASE_DIR" ]; then
      if [ "$(ls -A $SKYWALKING_AGENT_BASE_DIR)" ]; then
        log_info "SkyWalking Agent已存在且非空，跳过下载和安装"
        
        # 配置应用的SkyWalking Agent
        if [ -d "$APP_BASE_DIR" ]; then
          # 排除backup目录
          for app_dir in $(find $APP_BASE_DIR -mindepth 1 -maxdepth 1 -type d ! -name "backup"); do
            app_name=$(basename $app_dir)
            target_agent_dir="$SW_HOME/$app_name"
            
            # 如果目标目录已存在，则跳过
            if [ -d "$target_agent_dir" ]; then
              log_warn "应用 $app_name 的 agent 目录已存在，跳过创建"
              continue
            fi
            
            # 创建符号链接
            echo "为应用 $app_name 创建SkyWalking Agent链接..."
            ln -s $SKYWALKING_AGENT_BASE_DIR $target_agent_dir
            
            # 创建agent配置文件
            agent_config_dir="$target_agent_dir/config"
            mkdir -p $agent_config_dir
            agent_config_file="$agent_config_dir/agent.config"
            
            # 拷贝默认配置
            if [ ! -f "$agent_config_file" ]; then
              log_info "创建agent配置文件: $agent_config_file"
              cp $SKYWALKING_AGENT_BASE_DIR/config/agent.config $agent_config_file
            fi
            
            # 修改 agent.config
            if [ -f "$agent_config_file" ]; then
              # 使用兼容的sed命令格式
              if [[ "$(uname -s)" == "Darwin" ]]; then
                # macOS需要额外参数
                sed -i "" "s/agent.service_name=.*/agent.service_name=${app_name}/" "$agent_config_file"
              else
                sed -i "s/agent.service_name=.*/agent.service_name=${app_name}/" "$agent_config_file"
              fi
              log_info "已设置 agent.service_name=$app_name"
            else
              log_warn "配置文件不存在: $agent_config_file"
            fi
            
            # 输出JVM参数
            jvm_param="-javaagent:$target_agent_dir/skywalking-agent.jar -Dskywalking.agent.service_name=$app_name -Dskywalking.collector.backend_service=localhost:11800"
            echo "📌 JVM 参数（$app_name）:"
            echo "$jvm_param"
          done
        fi
        
        return 0
      fi
    fi
    
    echo "正在下载并安装SkyWalking Agent..."
    # 确保目标目录存在
    mkdir -p "$SKYWALKING_AGENT_BASE_DIR"
    
    if [ ! -f $SKYWALKING_AGENT_TGZ ]; then
      wget -q -O "$SKYWALKING_AGENT_TGZ" "$SKYWALKING_AGENT_DOWNLOAD_URL"
    fi
    
    # 检查是否已经解压
    if [ ! -d "$SKYWALKING_AGENT_BASE_DIR/apache-skywalking-java-agent-$SKYWALKING_AGENT_VERSION" ]; then
      tar -xzf $SKYWALKING_AGENT_TGZ -C $SKYWALKING_AGENT_BASE_DIR --strip-components=1
    fi
    
    # 删除压缩包
    rm -f $SKYWALKING_AGENT_TGZ
}

# 启动 SkyWalking
function start_sw () {
  # 检查目录是否存在
  if [ ! -d "$SW_HOME/bin" ]; then
    log_error "SkyWalking安装目录不存在: $SW_HOME/bin"
    exit 1
  fi
  
  # 进入bin目录
  cd $SW_HOME/bin
  
  # 启动 backend
  echo "启动SkyWalking..."
  nohup ./oapService.sh > /dev/null 2>&1 &
  
  # 启动 UI
  echo "启动SkyWalking UI..."
  nohup ./webappService.sh > /dev/null 2>&1 &
}

# 检查日志文件
function check_logs() {
  # 等待日志文件生成
  sleep 5
  
  # 检查OAP日志
  if [ -f "$SW_HOME/logs/skywalking-oap-server.log" ]; then
    echo "SkyWalking OAP日志路径: $SW_HOME/logs/skywalking-oap-server.log"
  else
    echo "警告: SkyWalking OAP日志文件未找到"
  fi
  
  # 检查WebApp日志
  if [ -f "$SW_HOME/logs/skywalking-webapp.log" ]; then
    echo "SkyWalking WebApp日志路径: $SW_HOME/logs/skywalking-webapp.log"
  else
    echo "警告: SkyWalking WebApp日志文件未找到"
  fi
}

# 主函数
function main () {
  check_os
  download_sw
  extract_sw
  configure_sw
  start_sw
  configure_skywalking_agent
  check_logs
}

main
