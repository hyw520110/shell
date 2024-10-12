#!/bin/bash

# PostgreSQL 版本
pg_version="15"

# 导入公共脚本
source ../linux/os_common.sh


# 添加 PostgreSQL 仓库
add_postgresql_repo() {
    local os_type=$(detect_os)
    local pkg_mgr=$(command -v apt || command -v dnf || command -v yum)
    local major_version=$(cat /etc/os-release | grep VERSION_ID | cut -d '"' -f 2 | awk -F'.' '{print $1}')
    local basearch=$(uname -m)

    case $os_type in
        "Deepin"|"Debian"|"Ubuntu")
            echo "添加 PostgreSQL 仓库..."
            # 导入仓库签名密钥
            sudo apt install -y curl ca-certificates
            sudo install -d /usr/share/postgresql-common/pgdg
            sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
            # 使用正确的代号
            codename=$(get_debian_codename)
            echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
            sudo apt update
            ;;
        "CentOS"|"Fedora"|"RedHat")
            echo "添加 PostgreSQL 仓库..."
            sudo rpm -Uvh https://download.postgresql.org/pub/repos/yum/reporpms/EPG-$pg_version-rhel$major_version-$basearch.rpm
            ;;
        *)
            echo "不支持的操作系统。"
            exit 1
            ;;
    esac
}

# 安装 PostgreSQL
install_postgresql() {
    echo "安装 PostgreSQL..."
    if command -v apt &> /dev/null; then
        sudo apt -y install postgresql-$pg_version  postgresql-$pg_version-pgvector
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y postgresql$pg_version-server postgresql$pg_version-contrib libpgvector-devel
    elif command -v yum &> /dev/null; then
        sudo yum install -y postgresql$pg_version-server postgresql$pg_version-contrib libpgvector-devel
    fi
}

# 配置 PostgreSQL
configure_postgresql() {
    echo "配置 PostgreSQL..."
    read -t 5 -p "请输入postgresql用户名 (默认为postgres): " username
    username=${username:-postgres}
    if ! id -u $username > /dev/null 2>&1; then
        sudo useradd -r -s /bin/false -d /var/lib/postgresql $username
    fi
    password=$(openssl rand -base64 12)
    echo -e "密码:${RED}${password}${NC}"
    sudo -u postgres psql -c "ALTER USER $username WITH PASSWORD '$password';"
#    sudo -u postgres psql -c "CREATE DATABASE mydatabase;"
#    sudo -u postgres psql mydatabase -c "CREATE TABLE test (id serial PRIMARY KEY, num integer, data varchar);"
    echo "安装 pgvector 扩展..."
    sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS vector;"
}

# 启动 PostgreSQL 服务
start_postgresql() {
    echo "启动 PostgreSQL 服务..."
    sudo systemctl start postgresql
    sudo systemctl enable postgresql
}

# 检查 PostgreSQL 服务状态
check_service_status() {
  if systemctl is-active "postgresql" &> /dev/null; then
    echo -e "${GREEN}PostgreSQL 服务正在运行。${NC}"
  else
    echo -e "${RED}PostgreSQL 服务未运行。${NC}"
    systemctl status "postgresql"
  fi
}
check_permission
install_dependencies
add_postgresql_repo
install_postgresql
configure_postgresql
start_postgresql
check_service_status