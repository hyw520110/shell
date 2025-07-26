#!/bin/bash
# nacos安装、启动脚本，默认单机模式，可交互式选择集群模式，集群ip交互式输入.

# --- 全局变量和环境检查 ---

# 获取操作系统类型
OS_TYPE=$(uname -s)

# 默认端口，集群模式下的节点服务端口
port=8848
# 获取用户输入的安装目录，如果未输入则使用默认路径
INSTALL_DIR="${1:-/opt/nacos}"

# 获取当前脚本所在目录和项目根目录
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR=$(cd "$(dirname "$0")"/..; pwd)
# 下载url (nacos3 要求17)
url="https://github.com/alibaba/nacos/releases/download/3.0.2/nacos-server-3.0.2.tar.gz"
gz_file_name=${url##*/}
tmp_dir=/tmp
gz_file=$tmp_dir/$gz_file_name

# 集群配置文件
cluster_file=$BASE_DIR/conf/cluster.conf
# 记录是否初始化第一次启动
init_file=~/.nacos_init
# 自启动服务脚本 (仅Linux)
s_file=/usr/lib/systemd/system/nacos.service

# --- 函数定义 ---

# 获取本机主 IP 地址（跨平台）
get_main_ip() {
    if [ "$OS_TYPE" = "Linux" ]; then
        ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
    elif [ "$OS_TYPE" = "Darwin" ]; then
        local interface
        interface=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')
        if [ -n "$interface" ]; then
            ifconfig "$interface" 2>/dev/null | awk '$1 == "inet" {print $2}'
        else
            ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1
        fi
    else
        ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -n 1
    fi
}

# 获取本机IP
ip=$(get_main_ip)

# 兼容不同系统的sed -i命令
sed_inplace() {
    if [ "$OS_TYPE" = "Darwin" ]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# 查看实时日志
tailfLog() {
    sleep 3
    local log_file="$BASE_DIR/logs/startup.log"
    local tail_opts="$1" # e.g., -f
    if [ -f "$log_file" ]; then
        tail -n 100 "$tail_opts" "$log_file"
    else
        echo "日志文件 $log_file 未找到。"
    fi
}

# 判断文本在文件中不存在时，写入文本到文件
wfile() {
    if [ -f "$2" ] && ! grep -qF "$1" "$2"; then
        echo "$1" >> "$2"
    fi
}

# 远程拷贝 (集群功能)
remoteInstall() {
    local target_host="$1"
    echo "请确保到 $target_host 的SSH免密登录已配置。"
    rsync -aWPu --exclude "logs" "$BASE_DIR/" "${target_host}:${BASE_DIR%/nacos*}"
    ssh -o StrictHostKeyChecking=no "root@$target_host" > /dev/null 2>&1 << EOF
chmod +x $CURRENT_DIR/*.sh
$CURRENT_DIR/${0##*/} "$1" >/dev/null 2>&1 &
exit
EOF
}

# 下载并解压
download_and_extract() {
    local extra_dir="$1"
    [ ! -f "$gz_file" ] && wget -c "$url" -O "$gz_file"
    extracted_name=$(tar -tzf "$gz_file" | head -1 | cut -f1 -d"/")
    if [ -d "$extra_dir/$extracted_name" ]; then
        read -p "解压目录 $extra_dir/$extracted_name 已存在。是否覆盖？(y/n)" extra_confirm
        if [ "$extra_confirm" != "y" ]; then
            echo "取消解压。"
            exit
        fi
    fi
    echo "正在解压 $gz_file 到 $extra_dir ..."
    tar -zxf "$gz_file" -C "$extra_dir"
    if [ $? -ne 0 ]; then
        echo "解压失败，请检查压缩包或权限。"
        exit 1
    fi
}

# 安装主函数
install_main() {
    if [ ! -f "$INSTALL_DIR/target/nacos-server.jar" ] || [ ! -d "$INSTALL_DIR/conf" ]; then
        echo "Nacos未安装，开始安装过程..."
        if [ ! -w "$tmp_dir" ]; then
            echo "错误：临时目录 $tmp_dir 没有写权限。" && exit 1
        fi

        extracted_name=$(tar -tzf "$gz_file" | head -1 | cut -f1 -d"/")
        # 智能解压逻辑：如果安装目录是nacos结尾则直接解压到安装目录，否则解压到临时目录再拷贝到安装目录
        if [ "$(basename $INSTALL_DIR)" != "$extracted_name" ]; then
            download_and_extract $tmp_dir
            echo "拷贝到安装目录：$INSTALL_DIR"
            rsync -aWPu "$tmp_dir/$extracted_name/*" "$INSTALL_DIR/"
        else
            echo "解压到安装目录：$INSTALL_DIR"
            download_and_extract $(dirname "$INSTALL_DIR")
        fi
         if [ "$SUDO_USER" != "" ]; then
              # 如果是通过sudo运行，则将所有权设置给sudo的原始用户
              chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) $INSTALL_DIR
          else
              # 否则使用当前用户
              chown -R $(id -u):$(id -g) $INSTALL_DIR
          fi
        echo "Nacos安装完成。"
    else
        echo "Nacos已安装，跳过安装过程。"
    fi
}
# 重构配置更新函数
update_config_value() {
    local config_file="$1"
    local key="$2"
    local value="$3"

    if [[ ! -f "$config_file" ]]; then
        echo "错误：配置文件不存在 '$config_file'" && return 1
    fi

    # 对key中的.进行转义，以用于正则表达式
    local sed_key
    sed_key=$(echo "$key" | sed -e 's/\./\\./g')

    # 检查key是否存在（无论是否被注释）
    if grep -qE "^[[:space:]]*#?[[:space:]]*${sed_key}" "$config_file"; then
        # 如果存在，则替换该行，取消注释并设置为新值
        echo "正在更新配置文件：$config_file 中的配置项 '$key'..."
        # 判断指定的值是否为空,如果为空则只取消注释即可不要更改值
        if [ -z "$value" ]; then
            sed_inplace "s|^[[:space:]]*#*[[:space:]]*${sed_key}=.*|${key}=|" "$config_file"
        else
            sed_inplace "s|^[[:space:]]*#*[[:space:]]*${sed_key}=.*|${key}=${value}|" "$config_file"
        fi
    else
        # 如果不存在，则在文件末尾添加
        echo "配置文件：$config_file 中配置项 '$key' 不存在，正在添加..."
        echo "${key}=${value}" >> "$config_file"
    fi
    return 0
}


# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 sudo 权限运行此脚本。" && exit 1
fi

# 检查端口占用
if lsof -i :"$port" -sTCP:LISTEN -t >/dev/null ; then
    echo "错误：端口 $port 已被占用。" && exit 1
fi

# 检查进程是否已运行
if ps -ef | grep "nacos.jar" | grep -v "grep" > /dev/null; then
    echo "Nacos 已在运行。" && exit 0
fi

# 执行安装
install_main
#  检查INSTALL_DIR和BASE_DIR不相等则拷贝BASE_DIR下的文件到INSTALL_DIR
if [ "$INSTALL_DIR" != "$BASE_DIR" ]; then
    cp -r "$BASE_DIR"/* "$INSTALL_DIR"
    BASE_DIR="$INSTALL_DIR"
fi
conf_file="$INSTALL_DIR/conf/application.properties"
if [ ! -f "$conf_file" ]; then
    echo "错误：找不到配置文件 $conf_file " && exit 1
fi

# 配置数据库
echo "--- 开始配置数据库 ---"
update_config_value "$conf_file" "spring.datasource.platform" "mysql"
update_config_value "$conf_file" "db.num" "1"

# 检查 mysql-server 是否可解析
MYSQL_HOST="mysql-server"
if grep -q "$MYSQL_HOST" $conf_file && ! ping -c 1 "$MYSQL_HOST" &> /dev/null; then
    echo "无法连接到默认MySQL主机 '$MYSQL_HOST'。"
    read -p "请输入 MySQL 服务器 IP 地址 (默认为: $ip): " MYSQL_IP
    MYSQL_IP=${MYSQL_IP:-$ip}
    sed -i '' "s#mysql-server#$MYSQL_IP#" "$conf_file"
fi
update_config_value "$conf_file" "db.url.0"

read -p "请输入 MySQL 用户名 (默认: root): " MYSQL_USER
MYSQL_USER="${MYSQL_USER:-root}"
read -s -p "请输入 MySQL 密码 (如果留空将生成随机密码): " MYSQL_PASSWORD
echo

if [ -z "$MYSQL_PASSWORD" ]; then
    MYSQL_PASSWORD=$(LC_CTYPE=C tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)
    echo "已生成随机密码: $MYSQL_PASSWORD"
fi

update_config_value "$conf_file" "db.user.0" "$MYSQL_USER"
update_config_value "$conf_file" "db.password.0" "$MYSQL_PASSWORD"

echo "数据源已更新:"
grep "^db." "$conf_file"
touch "$init_file"

# 安全配置
echo "--- 正在配置安全密钥 ---"
secret_key=$(LC_CTYPE=C tr -dc 'A-Za-z0-9+/=' < /dev/urandom | head -c 44)
identity_key=$(LC_CTYPE=C tr -dc 'A-Za-z0-9+/=' < /dev/urandom | head -c 44)
identity_value=$(LC_CTYPE=C tr -dc 'A-Za-z0-9+/=' < /dev/urandom | head -c 44)

update_config_value "$conf_file" "nacos.core.auth.plugin.nacos.token.secret.key" "$secret_key"
update_config_value "$conf_file" "nacos.core.auth.server.identity.key" "$identity_key"
update_config_value "$conf_file" "nacos.core.auth.server.identity.value" "$identity_value"

# 模式选择与启动
read  -n 1 -p "是否以单机模式启动? (Y/n): " choice
echo
choice=${choice:-Y}

if [[ "$choice" =~ ^[Yy]$ ]]; then
    echo "单机模式启动..."
     if [ -n "$SUDO_USER" ]; then
          chown -R $(id -u $SUDO_USER):$(id -g $SUDO_USER) "$BASE_DIR/"
          sudo -u "$SUDO_USER" "$BASE_DIR/bin/startup.sh" -m standalone
      else
          "$BASE_DIR/bin/startup.sh" -m standalone
      fi
    tailfLog
    exit 0
fi

echo "集群模式启动..."
# 集群配置逻辑
wfile "${ip}:${port}" "$cluster_file"

while : ; do
    read -p "请输入其他集群节点的IP地址 (多个IP用空格隔开, 输入q退出): " cluster_ips
    if [[ "$cluster_ips" == "q" ]]; then break; fi
    if [ -n "$cluster_ips" ]; then
        for node_ip in $cluster_ips; do
            wfile "${node_ip}:${port}" "$cluster_file"
            echo "--- 正在向 $node_ip 同步并启动 ---"
            remoteInstall "$node_ip" && wait $!
        done
        break
    
    fi
done

echo "启动当前节点..."
"$BASE_DIR/bin/startup.sh"
tailfLog -f

exit 0