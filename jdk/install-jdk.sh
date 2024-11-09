#!/bin/bash
# jdk自动安装、配置

# 默认版本为 8
JAVA_VERSION=${1:-8}

# 定义变量
declare -A JAVA_INFO=(
  [8]="/opt/dragonwell-8.11.12 https://github.com/alibaba/dragonwell8/releases/download/dragonwell-8.11.12_jdk8u332-ga/Alibaba_Dragonwell_8.11.12_x64_linux.tar.gz"
  [11]="/opt/jdk-11.0.2 https://download.java.net/java/GA/jdk11/9/GPL/openjdk-11.0.2_linux-x64_bin.tar.gz"
  [21]="/opt/dragonwell-21.0.4.0.4.7 https://dragonwell.oss-cn-shanghai.aliyuncs.com/21.0.4.0.4%2B7/Alibaba_Dragonwell_Extended_21.0.4.0.4.7_x64_linux.tar.gz"
)

gz_file=/opt/softs/${JAVA_INFO[$JAVA_VERSION]##*/}
p_file=/etc/profile.d/java.sh

# 检查操作系统
function check_os () {
  if [ -f /etc/redhat-release ]; then
    OS="CentOS"
  elif [ -f /etc/debian_version ]; then
    OS="Debian"
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
  if [ "$OS" == "CentOS" ]; then
    update-alternatives --list | grep java
  elif [ "$OS" == "Debian" ]; then
    sudo update-alternatives --list java
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

  if [ -d $home_dir ]; then
    echo "Java $version 已安装在 $home_dir"
    return 0
  fi

  # 检查是否注册到 update-alternatives
  if listjava | grep -q "$home_dir/bin/java"; then
    echo "Java $version 已注册到 update-alternatives"
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
    wget $url -O $gz_file
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
      sed -i "s|^JAVA_HOME=.*|JAVA_HOME=$home_dir|" "$file"
      sed -i "s|^PATH=.*|PATH=\$JAVA_HOME/bin:\$PATH|" "$file"
    fi
  done

  if ! $found; then
    profile_file=/etc/profile
    if [ -d /etc/profile.d ]; then
      profile_file=$p_file
      chmod +x $p_file
    fi
    cat <<EOF > $profile_file
JAVA_HOME=$home_dir
export JAVA_HOME
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
    source /etc/profile
  fi
}

# 注册 Java 组件到 update-alternatives
function register_alternatives () {
  local home_dir=$1
  local priority=$2

  if [ -d $home_dir ]; then
    sudo update-alternatives --install /usr/bin/java java $home_dir/bin/java $priority
    sudo update-alternatives --install /usr/bin/javac javac $home_dir/bin/javac $priority
    sudo update-alternatives --install /usr/bin/jar jar $home_dir/bin/jar $priority
  else
    echo "Java 目录 $home_dir 不存在。"
    exit 1
  fi
}

# 更新 alternatives 并切换 Java 版本
function update_and_switch_alternatives () {
  local home_dir=$1
  local priority=$2

  if [ -d $home_dir ]; then
    sudo update-alternatives --set java $home_dir/bin/java
    sudo update-alternatives --set javac $home_dir/bin/javac
    sudo update-alternatives --set jar $home_dir/bin/jar
  else
    echo "Java 目录 $home_dir 不存在。"
    exit 1
  fi
}

# 安装 Java
function install_java () {
  local version=$1
  local home_dir=${JAVA_INFO[$version]%% *}
  local url=${JAVA_INFO[$version]#* }

  if check_installed_java $version; then
    echo "Java $version 已经安装。"
    return
  fi

  download_and_extract $url $home_dir $gz_file
  priority=$((count + 3 - version))
  register_alternatives $home_dir $priority
  update_and_switch_alternatives $home_dir $priority
  set_environment_variables $home_dir
}

# 主函数
function main () {
  check_os
  check_permissions

  count=$(listjava | grep -Ev "grep|javac" | wc -l)
  current_version=$(javaversion)

  echo "当前 Java 版本: $current_version"

  if [[ -v JAVA_INFO[$JAVA_VERSION] ]]; then
    install_java $JAVA_VERSION
  else
    echo "不支持的 Java 版本: $JAVA_VERSION"
    exit 1
  fi

  listjava
  echo "新的 Java 版本: $(javaversion)"
}

main