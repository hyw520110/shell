#!/bin/bash

set -e

# 默认配置
DEFAULT_PORT=3080
REPO_URL="https://github.com/hunshcn/gh-proxy.git"
INSTALL_DIR="/opt/gh-proxy"
SERVICE_NAME="gh-proxy"
FLASK_APP="$INSTALL_DIR/app/main.py"

echo "🚀 欢迎使用 gh-proxy 一键部署脚本！"
echo "请选择部署方式："
echo "1) Docker 部署"
echo "2) Python 原生部署"
read -p "请输入选项 (1 或 2): " DEPLOY_MODE

function install_dependencies_docker() {
    echo "📦 正在安装 Docker 和相关依赖..."
    if command -v apt &>/dev/null; then
        apt update -y && apt install -y docker.io
    elif command -v yum &>/dev/null; then
        yum install -y docker
        systemctl start docker
        systemctl enable docker
    else
        echo "❌ 无法识别包管理器，请手动安装 docker"
        exit 1
    fi
}

function deploy_with_docker() {
    echo "🐋 正在使用 Docker 部署 gh-proxy..."
    read -p "请输入要暴露的端口 (默认 $DEFAULT_PORT): " DOCKER_PORT
    DOCKER_PORT=${DOCKER_PORT:-$DEFAULT_PORT}

    echo "📥 拉取镜像并启动容器..."
    docker run -d \
        --name="gh-proxy-py" \
        -p "0.0.0.0:${DOCKER_PORT}:80" \
        --restart=always \
        hunsh/gh-proxy-py:latest

    echo "✅ gh-proxy 已成功运行！访问地址：http://$(hostname -I | awk '{print $1}'):${DOCKER_PORT}"
}

function install_dependencies_python() {
    echo "📦 正在安装 Python 及依赖..."
    if command -v apt &>/dev/null; then
        apt update -y && apt install -y git python3 python3-pip
    elif command -v yum &>/dev/null; then
        yum install -y git python3 python3-pip
    else
        echo "❌ 无法识别包管理器，请手动安装 git、python3、pip"
        exit 1
    fi

    pip3 install flask requests
}

function deploy_with_python() {
    echo "📂 正在克隆仓库到 $INSTALL_DIR ..."
    if [ ! -d "$INSTALL_DIR" ];then
    	mkdir -p "$INSTALL_DIR" 
		cd "$INSTALL_DIR" && git clone "$REPO_URL" .
	else
		cd "$INSTALL_DIR"
	fi
    
    echo "🔧 修改配置文件 app/main.py 中的监听端口..."
    sed -i "s|app.run(host='0.0.0.0', port=.*|app.run(host='0.0.0.0', port=$DEFAULT_PORT)|" app/main.py

    echo "🔧 添加响应头处理代码以避免错误..."
    sed -i '/headers = ProxyUtil.build_headers()/a\    if '\''Transfer-Encoding'\'' in headers:\n        headers.pop(\''Transfer-Encoding'\'')' app/main.py

    echo "⚙️ 创建 systemd 服务文件..."
    sudo cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=GH-Proxy Python Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 $FLASK_APP
WorkingDirectory=$INSTALL_DIR
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    echo "🔁 启动并启用服务..."
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "✅ gh-proxy 已成功安装并运行！"
        echo "🌐 访问地址: http://$(hostname -I | awk '{print $1}'):$DEFAULT_PORT"
        echo "📄 配置文件路径: $INSTALL_DIR/app/main.py"
        echo "🔄 如需修改配置，请编辑 main.py 后重启服务: systemctl restart $SERVICE_NAME"
    else
        echo "❌ gh-proxy 未能正常启动，请查看日志: journalctl -u $SERVICE_NAME -n 20"
    fi
}

# 主逻辑
case "$DEPLOY_MODE" in
    1)
        install_dependencies_docker
        deploy_with_docker
        ;;
    2)
        install_dependencies_python
        deploy_with_python
        ;;
    *)
        echo "❌ 无效选项，请输入 1 或 2"
        exit 1
        ;;
esac
