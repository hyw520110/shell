#!/bin/bash
# nacos安装、启动脚本，默认单机模式，可交互式选择集群模式，集群ip交互式输入.

# --- 全局变量和环境检查 ---

# 获取操作系统类型
OS_TYPE=$(uname -s)

# 默认端口，集群模式下的节点服务端口
port=8848
# 获取用户输入的安装目录，如果未输入则使用默认路径
INSTALL_DIR="${1:-/opt/nacos}"
# 获取用户输入的源码目录，如果未输入则使用默认下载方式
SOURCE_DIR="$2"

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

check_java_version() {
	version=${1:-17}
    # 检查Java是否安装
    if ! command -v java &> /dev/null; then
        echo "错误：Java未安装，请先安装Java $version。"
        return 1
    fi
    # 获取Java版本信息（处理不同平台的输出）
    java_version=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    # 提取主版本号
    if [[ $java_version == 1.* ]]; then
        # 处理旧版Java格式 (1.x.x)
        major_version=$(echo "$java_version" | awk -F '.' '{print $2}')
    else
        # 处理新版Java格式 (x.x.x)
        major_version=$(echo "$java_version" | awk -F '.' '{print $1}')
    fi

    # 检查主版本是否为17
    if [[ $major_version == $version ]]; then
        echo "Java版本符合要求：$$version"
        return 0
    else
        echo "需要Java $$version，但当前版本是 $major_version"
        return 1
    fi
}
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
    local log_file="$BASE_DIR/logs/startup.log"
    [ ! -f $log_file ] && sleep 5
    local tail_opts="$1" 
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

# 从源码构建并安装
build_from_source() {
    local source_dir="$1"
    local target_dir="$2"
    
    echo "从源码目录构建: $source_dir"
    
    # 检查源码目录是否存在
    if [ ! -d "$source_dir" ]; then
        echo "错误：源码目录 $source_dir 不存在"
        exit 1
    fi
    
    # 检查是否包含pom.xml文件
    if [ ! -f "$source_dir/pom.xml" ]; then
        echo "错误：源码目录中未找到 pom.xml 文件"
        exit 1
    fi
    
    # 检查distribution/target目录下是否已经有.tar.gz文件
    local dist_target_dir="$source_dir/distribution/target"
    local tar_gz_file=$(find "$dist_target_dir" -name "*.tar.gz" -type f 2>/dev/null | head -n 1)
    
    if [ -z "$tar_gz_file" ]; then
        echo "未在 $dist_target_dir 目录下找到 .tar.gz 文件，开始编译源码..."
        
        # 进入源码目录并执行mvn命令
        cd "$source_dir"
        mvn -Prelease-nacos clean install -Dmaven.test.skip=true -Drat.skip=true
        
        # 再次查找.tar.gz文件
        tar_gz_file=$(find "$dist_target_dir" -name "*.tar.gz" -type f 2>/dev/null | head -n 1)
        
        if [ -z "$tar_gz_file" ]; then
            echo "错误：编译完成后仍未在 $dist_target_dir 目录下找到 .tar.gz 文件"
            exit 1
        fi
    else
        echo "找到已有的构建文件: $tar_gz_file"
    fi
    
    # 解压.tar.gz文件到安装目录
    echo "正在解压 $tar_gz_file 到 $target_dir ..."
    mkdir -p "$target_dir"
    tar -zxf "$tar_gz_file" -C "$target_dir" --strip-components=1
    
    if [ $? -ne 0 ]; then
        echo "解压失败，请检查压缩包或权限。"
        exit 1
    fi
    
    echo "源码构建并解压完成。"
}

# 安装主函数
install_main() {
    if [ ! -f "$INSTALL_DIR/target/nacos-server.jar" ] || [ ! -d "$INSTALL_DIR/conf" ]; then
        echo "Nacos未安装，开始安装过程..."
        if [ ! -w "$tmp_dir" ]; then
            echo "错误：临时目录 $tmp_dir 没有写权限。" && exit 1
        fi
        
        # 如果提供了源码目录，则从源码构建
        if [ -n "$SOURCE_DIR" ]; then
            build_from_source "$SOURCE_DIR" "$INSTALL_DIR"
        else
            # 原有的下载安装逻辑
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
    if grep -qE "^#?[[:space:]]*${sed_key}" "$config_file"; then
        # 如果存在，则替换该行，取消注释并设置为新值
        echo "正在更新配置文件：$config_file 中的配置项 '$key'..."
        # 判断指定的值是否为空,如果为空则只取消注释即可不要更改值
        if [ -z "$value" ]; then
            sed_inplace "s|^#*[[:space:]]*${sed_key}=|${key}=|" "$config_file"
        else
            sed_inplace "s|^#*[[:space:]]*${sed_key}=.*|${key}=${value}|" "$config_file"
        fi
    else
        # 如果不存在，则在文件末尾添加
        echo "配置文件：$config_file 中配置项 '$key' 不存在，正在添加..."
        echo "${key}=${value}" >> "$config_file"
    fi
    return 0
}

# 检查MySQL连接是否可达
check_mysql_connection() {
    local mysql_host="$1"
    local mysql_port="$2"
    
    echo "正在检查MySQL连接: $mysql_host:$mysql_port..."
    
    # 使用nc命令检查端口连通性
    if command -v nc >/dev/null 2>&1; then
        if nc -z "$mysql_host" "$mysql_port" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    # 使用telnet命令检查端口连通性
    elif command -v telnet >/dev/null 2>&1; then
        if timeout 5 telnet "$mysql_host" "$mysql_port" 2>&1 | grep -q "Connected"; then
            return 0
        else
            return 1
        fi
    else
        # 如果没有nc或telnet，则尝试ping主机
        if ping -c 1 "$mysql_host" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    fi
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


# 提取配置文件中的MySQL连接信息
# 首先尝试获取未注释的配置
DB_URL=$(grep "^db.url.0=" "$conf_file" | head -n 1 | cut -d'=' -f2-)
if [ -z "$DB_URL" ]; then
    # 尝试获取被注释掉的配置（兼容前面可能有0个或多个空格的情况）
    DB_URL=$(grep "^#[[:space:]]*db.url.0=" "$conf_file" | head -n 1 | cut -d'=' -f2-)
fi
# 从URL中提取主机和端口，仅提取//和第一个?之间的内容
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
HOST_AND_PORT=""

if [ -n "$DB_URL" ]; then
    # 提取//和第一个?之间的内容，然后从中提取主机和端口
    HOST_AND_PORT=$(echo "$DB_URL" | sed -E 's/.*jdbc:mysql:\/\/([^\/?]+).*/\1/')
    if [ -n "$HOST_AND_PORT" ]; then
        # 进一步提取主机:端口部分（处理可能的路径）
        HOST_PORT_PART=$(echo "$HOST_AND_PORT" | cut -d'/' -f1)
        MYSQL_HOST=$(echo "$HOST_PORT_PART" | cut -d':' -f1)
        MYSQL_PORT=$(echo "$HOST_PORT_PART" | cut -d':' -f2)
    fi
fi
# echo "$MYSQL_HOST:$MYSQL_PORT"
# 如果配置文件中的连接信息不可达，则提示用户输入
if [ -n "$MYSQL_HOST" ] && [ -n "$MYSQL_PORT" ]; then
    if ! check_mysql_connection "$MYSQL_HOST" "$MYSQL_PORT"; then
        echo "配置文件中的MySQL连接 ($MYSQL_HOST:$MYSQL_PORT) 不可达"
        read -p "请输入 MySQL 服务器主机名/IP (默认为: $MYSQL_HOST): " MYSQL_HOST
        MYSQL_HOST=${MYSQL_HOST:-$MYSQL_HOST}
        read -p "请输入 MySQL 服务器端口 (默认为: $MYSQL_PORT): " PORT
        MYSQL_PORT=${PORT:-$MYSQL_PORT}
        # 直接替换URL中的主机和端口部分
        NEW_DB_URL=$(echo "$DB_URL" | sed "s|$HOST_AND_PORT|$MYSQL_HOST:$MYSQL_PORT|")
        NEW_DB_URL=${NEW_DB_URL//&/\\&}
        update_config_value "$conf_file" "db.url.0" "$NEW_DB_URL"
    else
        echo "配置文件中的MySQL连接 ($MYSQL_HOST:$MYSQL_PORT) 可达"
        # 如果连接可达，取消注释配置项
        update_config_value "$conf_file" "db.url.0" "$DB_URL"
    fi
else
    echo "未在配置文件中找到有效的MySQL连接信息"
fi


# 提取配置文件中的MySQL用户名
DB_USER=$(grep "^db.user=" "$conf_file" | sed 's/^db.user=//' | head -n 1)
if [ -z "$DB_USER" ]; then
    # 尝试获取被注释掉的配置
    DB_USER=$(grep "^#db.user=" "$conf_file" | sed 's/^#db.user=//' | head -n 1)
    if [ -n "$DB_USER" ]; then
        # 如果找到被注释的配置，使用它作为默认值
        read -p "请输入 MySQL 用户名 (默认: $DB_USER): " MYSQL_USER
        MYSQL_USER=${MYSQL_USER:-$DB_USER}
    else
        # 如果没有找到任何配置，使用root作为默认值
        read -p "请输入 MySQL 用户名 (默认: root): " MYSQL_USER
        MYSQL_USER=${MYSQL_USER:-root}
    fi
else
    # 如果找到已启用的配置，使用它作为默认值
    read -p "请输入 MySQL 用户名 (默认: $DB_USER): " MYSQL_USER
    MYSQL_USER=${MYSQL_USER:-$DB_USER}
fi

# 更新用户名配置
update_config_value "$conf_file" "db.user" "$MYSQL_USER"

# 处理MySQL密码
DB_PASSWORD=$(grep "^db.password=" "$conf_file" | sed 's/^db.password=//' | head -n 1)
if [ -z "$DB_PASSWORD" ]; then
    # 尝试获取被注释掉的配置
    DB_PASSWORD=$(grep "^#db.password=" "$conf_file" | sed 's/^#db.password=//' | head -n 1)
fi

# 提示用户输入密码
while true; do
    if [ -n "$DB_PASSWORD" ]; then
        # 如果找到配置，将其作为默认值显示（但不显示在命令行上）
        read -s -p "请输入 MySQL 密码 (已配置): " MYSQL_PASSWORD
        echo
    else
        # 没有找到配置，提示输入密码
        read -s -p "请输入 MySQL 密码: " MYSQL_PASSWORD
        echo
    fi
    
    # 检查密码是否为空
    if [ -z "$MYSQL_PASSWORD" ]; then
        echo "错误：MySQL密码不能为空，请重新输入。"
    else
        break
    fi
done

# 更新密码配置
update_config_value "$conf_file" "db.password" "$MYSQL_PASSWORD"

echo "数据源已更新:"
grep "db" "$conf_file" 
touch "$init_file"

# 安全配置
echo "--- 正在配置安全密钥 ---"
secret_key=$(LC_CTYPE=C tr -dc 'A-Za-z0-9+/=' < /dev/urandom | head -c 44)
identity_key=$(LC_CTYPE=C tr -dc 'A-Za-z0-9+/=' < /dev/urandom | head -c 44)
identity_value=$(LC_CTYPE=C tr -dc 'A-Za-z0-9+/=' < /dev/urandom | head -c 44)

update_config_value "$conf_file" "nacos.core.auth.plugin.nacos.token.secret.key" "$secret_key"
update_config_value "$conf_file" "nacos.core.auth.server.identity.key" "$identity_key"
update_config_value "$conf_file" "nacos.core.auth.server.identity.value" "$identity_value"
# java17的话需要在启动脚本中添加JVM参数不然会启动报错
if check_java_version 17; then
  # 添加解决Java 17容器兼容性问题的JVM参数
	OPT="${JAVA_OPT} --add-opens java.base/jdk.internal.platform=ALL-UNNAMED -XX:-UseContainerSupport"
	# 判断启动脚本中是否有JVM参数UseContainerSupport，如果没有则使用sed添加
	if ! grep -q "UseContainerSupport" "$BASE_DIR/bin/startup.sh"; then
	    echo "当前是java17需在启动脚本中添加JVM参数:$OPT"
        # 因为启动脚本中有多行JAVA_OPT,所以需要使用sed添加，添加到# JVM Configuration的后2行
        #sed_inplace '/^[[:space:]]*#\{1,\}[[:space:]]*JVM Configuration/,+1 {/^[[:space:]]*#\{1,\}[[:space:]]*JVM Configuration/ {n;n} s/^/JAVA_OPT=\"\$JAVA_OPT -XX:\+UseContainerSupport\"\n/}' "$BASE_DIR/bin/startup.sh"
	fi
fi
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
    tailfLog -f
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