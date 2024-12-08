#!/bin/bash
# jdk自动安装、配置

# 默认版本为 8
JAVA_VERSION=${1:-8}

JAVA_INFO=(
  [8]="/opt/dragonwell-8.11.12 https://github.com/alibaba/dragonwell8/releases/download/dragonwell-8.11.12_jdk8u332-ga/Alibaba_Dragonwell_8.11.12_x64_linux.tar.gz"
  [11]="/opt/jdk-11.0.2 https://download.java.net/java/GA/jdk11/9/GPL/openjdk-11.0.2_osx-x64_bin.tar.gz"
  [21]="/opt/dragonwell-21.0.4.0.4.7 https://dragonwell.oss-cn-shanghai.aliyuncs.com/21.0.4.0.4%2B7/Alibaba_Dragonwell_Extended_21.0.4.0.4.7_x64_macos.tar.gz"
)

gz_file=/tmp/${JAVA_INFO[$JAVA_VERSION]##*/}
p_file=/etc/profile.d/java.sh

# 检查操作系统
function check_os () {
  if command -v brew > /dev/null; then
    OS="macOS"
  elif command -v apt > /dev/null; then
    OS="Debian"
  elif command -v yum > /dev/null; then
    OS="CentOS"
  else
    echo "不支持的操作系统"
    exit 1
  fi
}

# 检查权限
function check_permissions () {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户或使用 sudo 运行此脚本。"
    exit 1
  fi
}

# 列出所有 Java 候选项
function listjava () {
  if [ "$OS" == "macOS" ]; then
    /usr/libexec/java_home -V | grep -E '^(\/.*\/jdk.*)'
  else
    update-alternatives --list | grep java
  fi
}

# 获取当前 Java 版本
function javaversion () {
  java -version 2>&1 | awk 'NR==1{gsub(/"/,"");print $3}'
}
# 检查 Java 是否已安装
function check_installed_java () {
  local version=$1
  local home_dir=${JAVA_INFO[$version]%% *}

  if [ -d "$home_dir" ]; then
    echo "Java $version 已安装在 $home_dir"
    return 0
  fi

  # 对于 macOS，检查是否通过 /usr/libexec/java_home 注册
  if [ "$OS" == "macOS" ] && /usr/libexec/java_home -V 2>/dev/null | grep -q "$home_dir"; then
    echo "Java $version 已注册到 /usr/libexec/java_home"
    return 0
  fi

  # 检查环境变量
  if [ -n "$JAVA_HOME" ] && [ -d "$JAVA_HOME" ]; then
    current_version=$(javaversion)
    if [[ $current_version == *"$version"* ]]; then
      echo "Java $version 已通过环境变量配置"
      return 0
    fi
  fi

  return 1
}
# 下载并解压 Java
function download_and_extract () {
  local url=$1
  local home_dir=$2
  local gz_file=$3

  if [ ! -d ${gz_file%/*} ]; then
    echo "创建目录 ${gz_file%/*}..."
    mkdir -p ${gz_file%/*}
  fi

  if [ ! -d $home_dir ] && [ ! -f $gz_file ]; then
    echo "下载 $url 到 $gz_file..."
    curl -L $url -o $gz_file
  fi

  if [ ! -d $home_dir ]; then
    echo "解压到 ${home_dir%/*}..."
    tar -zxf $gz_file -C ${home_dir%/*}
    if [ $? -ne 0 ]; then
      echo "解压 $gz_file 到 ${home_dir%/*} 失败。"
      exit 1
    fi
  fi
}

# 设置环境变量
function set_environment_variables () {
  local home_dir=$1
  env_files=("/etc/profile" "/etc/environment" "/etc/bash.bashrc" "/etc/profile.d/*.sh" "~/.bashrc" "~/.profile" "~/.bash_profile")
  found=false

  for file in "${env_files[@]}"; do
    if [ -f "$file" ] && grep -q "JAVA_HOME" "$file"; then
      found=true
      sed -i "" "s|^JAVA_HOME=.*|JAVA_HOME=$home_dir|" "$file"
      sed -i "" "s|^PATH=.*|PATH=\$JAVA_HOME/bin:\$PATH|" "$file"
    fi
  done

  if ! $found; then
    profile_file=~/.bash_profile
    cat <<EOF >> $profile_file
export JAVA_HOME=$home_dir
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
    source $profile_file
  fi
}

# 更新 macOS 的 Java Home
function update_macos_java_home () {
  local home_dir=$1
  sudo /usr/libexec/java_home -V 2>/dev/null | while read line; do
    if [[ $line =~ ^($home_dir) ]]; then
      sudo /usr/libexec/java_home -F $line
    fi
  done
}

# 安装 Java
function install_java () {
  local version=$1
  local home_dir=${JAVA_INFO[$version]%% *}
  local url=${JAVA_INFO[$version]#* }

  if check_installed_java $version; then
    echo "Java $version 已经安装。"
    # 将 Java 8 设置为默认版本
    if [ "$OS" == "macOS" ]; then
      update_macos_java_home $home_dir
    fi
    set_environment_variables $home_dir
    return
  fi

  download_and_extract $url $home_dir $gz_file
  if [ "$OS" == "macOS" ]; then
    update_macos_java_home $home_dir
  fi
  set_environment_variables $home_dir
}
function main () {
  check_os
  check_permissions

  count=$(listjava | grep -Ev "grep|javac" | wc -l)
  current_version=$(javaversion)

  echo "当前 Java 版本: $current_version"

  if [[ -n ${JAVA_INFO[$JAVA_VERSION]+x} ]]; then
    install_java $JAVA_VERSION
  else
    echo "不支持的 Java 版本: $JAVA_VERSION"
    exit 1
  fi

  listjava
  echo "新的 Java 版本: $(javaversion)"
}
main
