#!/bin/bash

# 默认的API端口
API_PORT=443

# JDK cacerts 默认密码
CACERTS_PASSWORD="changeit"

# 查找 JDK 安装路径
function find_jdk_path() {
    local java_path=$(update-alternatives --list | grep java-11|head -n 1|awk '{print $3}')
    local jdk_home=$(dirname $(dirname $java_path))
    echo "$jdk_home"
}

# 获取 JDK cacerts 文件路径
function get_cacerts_path() {
  local jdk_home=$1
  local cacerts_path="$jdk_home/lib/security/cacerts"
  if [ ! -f "$cacerts_path" ]; then
    echo "无法找到 cacerts 文件: $cacerts_path"
    exit 1
  fi
  echo "$cacerts_path"
}

# 使用 openssl 检查 API 证书
function check_api_certificate() {
  local domain=$1
  local port=$2
  echo "正在连接到 $domain:$port 以获取证书..."
  openssl s_client -connect $domain:$port -showcerts </dev/null >api_cert.pem 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "无法连接到 $domain:$port"
    exit 1
  fi
}

# 提取所有证书并检查是否存在于 cacerts 中
function check_and_import_certificates() {
  local cacerts_file=$1
  while read -r cert; do
    # 创建临时文件存放当前证书
    temp_cert_file=$(mktemp)
    echo "$cert" >$temp_cert_file

    # 调试输出：显示当前处理的证书
    echo "正在处理证书: "
    cat $temp_cert_file
    echo ""

    # 提取证书中的CN
    subject=$(openssl x509 -noout -subject -in $temp_cert_file | sed -n 's/^.*CN=$.*$$/\1/p')

    if [ -z "$subject" ]; then
      echo "无法从证书中提取主题名称: $cert"
      continue
    fi

    # 调试输出：显示提取的主题名称
    echo "提取的主题名称: $subject"

    # 检查证书是否已经存在于cacerts中
    alias=$(keytool -list -keystore $cacerts_file -storepass $CACERTS_PASSWORD -v | grep -B 10000 "$subject" | grep Alias)
    if [ -z "$alias" ]; then
      # 证书不存在于 cacerts 中，提供手动检测和导入步骤
      echo "证书未找到在 JDK cacerts 中:"
      manual_check_and_import "$cacerts_file" "$temp_cert_file" "$subject"
    else
      echo "证书已存在于 JDK cacerts 中:"
      echo "$alias"
    fi

    # 清理临时文件
    rm -f $temp_cert_file
  done < <(openssl x509 -inform pem -text -in api_cert.pem | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/ {print}')
}

# 手动检测和导入证书
function manual_check_and_import() {
  local cacerts_file=$1
  local cert_file=$2
  local subject=$3

  echo "请按照以下步骤手动检测和导入证书："
  echo "1. 检测证书是否在 cacerts 中："
  echo "   keytool -list -keystore $cacerts_file -storepass $CACERTS_PASSWORD -alias \"$subject\""
  read -p "按任意键继续... " dummy

  echo "2. 如果证书不存在，使用以下命令导入证书："
  echo "   keytool -import -trustcacerts -alias \"$subject\" -file $cert_file -keystore $cacerts_file -storepass $CACERTS_PASSWORD"
  read -p "按任意键继续... " dummy
}

# 主函数
function main() {
  # 检查是否有命令行参数
  if [ -z "$1" ]; then
    read -p "请输入 API 域名: " API_DOMAIN
    API_DOMAIN=${API_DOMAIN:-"api.pg-bo.me"}
  else
    API_DOMAIN=$1
  fi

  local jdk_home=$(find_jdk_path)
  echo "找到的 JDK 安装路径: $jdk_home"

  local cacerts_file=$(get_cacerts_path "$jdk_home")
  echo "找到的 cacerts 文件路径: $cacerts_file"

  check_api_certificate "$API_DOMAIN" "$API_PORT"

  # 检查每个证书是否在 JDK cacerts 中，并提供手动检测和导入步骤
  check_and_import_certificates "$cacerts_file"

  # 清理临时文件
  rm -f api_cert.pem
}

main "$@"