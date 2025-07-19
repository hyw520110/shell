#!/bin/bash

# 默认安装目录
INSTALL_DIR="/opt/jdk"

# 默认下载目录
DOWNLOAD_DIR="/tmp"

# 支持的 Java 版本及其下载地址
# Linux版本
JAVA_INFO=(
  [7]="https://cdn.azul.com/zulu/bin/zulu7.56.0.19-ca-jdk7.0.312-linux_x64.tar.gz"
  [8]="https://github.com/alibaba/dragonwell8/releases/download/dragonwell-8.11.12_jdk8u332-ga/Alibaba_Dragonwell_8.11.12_x64_linux.tar.gz"
  [11]="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.20.1%2B1/OpenJDK11U-jdk_x64_linux_hotspot_11.0.20.1_1.tar.gz"
  [17]="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12.1%2B1/OpenJDK17U-jdk_x64_linux_hotspot_17.0.12.1_1.tar.gz"
  [19]="https://github.com/adoptium/temurin19-binaries/releases/download/jdk-19.0.9.1%2B1/OpenJDK19U-jdk_x64_linux_hotspot_19.0.9.1_1.tar.gz"
  [21]="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.1.12%2B1/OpenJDK21U-jdk_x64_linux_hotspot_21.0.1.12_1.tar.gz"
)

# macOS版本
MAC_JAVA_INFO=(
  [7]="https://cdn.azul.com/zulu/bin/zulu7.56.0.19-ca-jdk7.0.312-macosx_x64.tar.gz"
  [8]="https://github.com/alibaba/dragonwell8/releases/download/dragonwell-8.11.12_jdk8u332-ga/Alibaba_Dragonwell_8.11.12_x64_macosx.tar.gz"
  [11]="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.20.1%2B1/OpenJDK11U-jdk_x64_macosx.tar.gz"
  [17]="https://mirrors.huaweicloud.com/openjdk/17.0.2/openjdk-17.0.2_macos-x64_bin.tar.gz"
  [19]="https://mirrors.huaweicloud.com/openjdk/19.0.2/openjdk-19.0.2_macos-x64_bin.tar.gz"
  [21]="https://mirrors.huaweicloud.com/openjdk/21.0.1/openjdk-21.0.1_macos-x64_bin.tar.gz"
)

# 使用说明
function usage() {
  echo "Usage: sudo $0 <version> [install_dir]"
  echo ""
  echo "如:"
  echo "  sudo ./install-jdk.sh 11"
  echo "  sudo ./install-jdk.sh 8 /opt/jdk"
  echo ""
  echo "支持版本: ${!JAVA_INFO[@]}"
  echo "必须使用 sudo 权限运行此脚本。"
  exit 1
}

# 检查权限
function check_permissions() {
  if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 sudo 权限运行此脚本。"
    usage
  fi
}

# 检查是否传入了版本号
function check_arguments() {
  if [ -z "$1" ]; then
    echo "错误：缺少 Java 版本参数。"
    usage
  fi

  if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "错误：Java 版本必须是数字。"
    usage
  fi

  if [ -z "${JAVA_INFO[$1]}" ]; then
    echo "错误：不支持的 Java 版本: $1"
    echo "支持的版本: ${!JAVA_INFO[@]}"
    usage
  fi
}

# 获取当前用户主目录
function get_user_home() {
  # 获取实际用户主目录，即使在sudo下
  local user=$(logname 2>/dev/null || echo $SUDO_USER || whoami)
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "/Users/$user"
  else
    echo "/home/$user"
  fi
}

# 安装缺失的解压工具
function install_extractor() {
  local ext=$1
  local pkg_mgr
  if command -v apt-get &> /dev/null; then
      pkg_mgr="apt-get -y"
  elif command -v yum &> /dev/null; then
      pkg_mgr="yum install -y"
  elif command -v dnf &> /dev/null; then
      pkg_mgr="dnf install -y"
  elif command -v brew &> /dev/null; then
      pkg_mgr="brew install "
  else
      echo "无法识别包管理工具，请手动安装所需工具。"
      exit 1
  fi
  case "$ext" in
    tar.gz|tgz) which gzip > /dev/null || $pkg_mgr gzip ;;
    tar.xz|txz) which xz > /dev/null || $pkg_mgr xz-utils  ;;
    zip)        which unzip > /dev/null || $pkg_mgr unzip  ;;
    *)
      echo "不支持的压缩格式: $ext"
      exit 1
      ;;
  esac
}

# 根据 URL 获取压缩包格式
function get_archive_type() {
  local url="$1"
  case "$url" in
    *.tar.gz|*.tgz) echo "tar.gz" ;;
    *.tar.xz|*.txz) echo "tar.xz" ;;
    *.zip)          echo "zip" ;;
    *)              echo "unknown" ;;
  esac
}

# 根据 URL 提取文件名
function get_filename_from_url() {
  local url="$1"
  echo "${url##*/}"
}
# 解压文件并返回解压目录
function extract_and_get_dir() {
  local file="$1"
  local target_dir="$2"
  local url="$3"

  # 根据 URL 判断压缩格式
  local ext=$(get_archive_type "$url")
  if [ "$ext" == "unknown" ]; then
    echo "无法识别压缩包格式，请检查下载链接。"
    exit 1
  fi

  # 安装必要的解压工具
  install_extractor "$ext"

  # 创建目标目录
  mkdir -p "$target_dir"
  case "$ext" in
    tar.gz|tgz)
      tar -zxpf "$file" -C "$target_dir"
      ;;
    tar.xz|txz)
      tar -Jxpf "$file" -C "$target_dir"
      ;;
    zip)
      unzip -q "$file" -d "$target_dir"
      ;;
  esac

  # 提取解压后的目录名
  local extracted_dir=$(ls -d "$target_dir"/*/ 2>/dev/null | head -n1)
  if [ -z "$extracted_dir" ]; then
    echo "无法识别解压后的目录结构，请检查压缩包内容。"
    exit 1
  fi

  echo "${extracted_dir%/}"  # 去除末尾斜杠
}

function switch_java() {
  local version=$1

  # 查找实际解压目录（精确匹配）
  local home_dir=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "jdk-$version.*" -o -name "jdk-$version" 2>/dev/null | head -n1)

  if [ -z "$home_dir" ]; then
    echo "未找到匹配的 Java 安装目录，请确认是否已成功解压。"
    exit 1
  fi

  # macOS 兼容性：检查 JDK 结构
  local java_home_path="$home_dir"
  if [[ "$(uname)" == "Darwin" ]] && [ -d "$home_dir/Contents/Home" ]; then
    java_home_path="$home_dir/Contents/Home"
  fi

  # 确保 bin/java 存在
  if [ ! -x "$java_home_path/bin/java" ]; then
    echo "错误：Java 可执行文件不存在或不可执行: $java_home_path/bin/java"
    echo "请确认 JDK 包结构是否完整。"
    exit 1
  fi

  # 创建统一符号链接（确保始终存在）
  ln -sf "$home_dir" "$INSTALL_DIR/jdk-$version"

  # 使用 update-alternatives 设置默认 java
  if command -v update-alternatives &>/dev/null; then
    update-alternatives --install /usr/bin/java java "$java_home_path/bin/java" 1
    update-alternatives --set java "$java_home_path/bin/java"
    echo "已切换到 Java $version (路径: $java_home_path)"
  else
    export JAVA_HOME="$java_home_path"
    export PATH="$JAVA_HOME/bin:$PATH"
    echo "已切换到 Java $version (路径: $JAVA_HOME)"
  fi
}

# 设置环境���量
function set_environment_variables() {
  local home_dir=$1
  # macOS 兼容性：检查 JDK 结构
  local java_home_path="$home_dir"
  if [[ "$(uname)" == "Darwin" ]] && [ -d "$home_dir/Contents/Home" ]; then
    java_home_path="$home_dir/Contents/Home"
  fi

  local user_home=$(get_user_home)
  local user=$(logname 2>/dev/null || echo $SUDO_USER || whoami)
  local user_shell

  if [[ "$(uname)" == "Darwin" ]]; then
    user_shell=$(dscl . -read "/Users/$user" UserShell | awk '{print $2}')
  else
    user_shell=$(getent passwd "$user" | cut -d: -f7)
  fi

  local profile_file
  if [[ "$user_shell" == *"zsh"* ]]; then
    profile_file="$user_home/.zshrc"
  else
    profile_file="$user_home/.bash_profile"
  fi

  # 如果文件不存在则创建
  if [ ! -f "$profile_file" ]; then
    touch "$profile_file"
    echo "已创建配置文件: $profile_file"
  fi

  # 删除旧的 JAVA_HOME 设置
  # macOS和Linux兼容的sed语法
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' '/^export JAVA_HOME/d' "$profile_file"
    sed -i '' '/^export PATH=.*\$JAVA_HOME/d' "$profile_file"
  else
    sed -i '/^export JAVA_HOME/d' "$profile_file"
    sed -i '/^export PATH=.*\$JAVA_HOME/d' "$profile_file"
  fi

  # 添加新的设置
  cat >> "$profile_file" <<EOF
export JAVA_HOME=$java_home_path
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

  echo "环境变量已更新，请重新启动终端或执行 'source $profile_file' 使设置生效。"
}

# 下载并解压 Java
function download_and_extract() {
  local url=$1
  local version=$2

  # 从 URL 提取文件名
  local filename=$(get_filename_from_url "$url")

  # 下载路径
  local gz_file="$DOWNLOAD_DIR/$filename"

  # 如果文件已存在，跳过下载
  if [ -f "$gz_file" ]; then
    echo "文件已存在，跳过下载: $gz_file"
  else
    echo "下载 $url 到 $gz_file..."
    if ! curl -L -f "$url" -o "$gz_file"; then
      echo "错误：下载失败，请检查网络连接或URL是否有效"
      rm -f "$gz_file"
      exit 1
    fi

    # 验证文件大小不为0
    if [ ! -s "$gz_file" ]; then
      echo "错误：下载的文件为空，请检查URL是否正确"
      rm -f "$gz_file"
      exit 1
    fi

    if [ $? -ne 0 ]; then
      echo "下载失败，请检查网络连接并重试。"
      rm -f "$gz_file"
      exit 1
    fi
  fi

  echo "解压中..."
  local extracted_dir=$(extract_and_get_dir "$gz_file" "$INSTALL_DIR" "$url")

  echo "Java 解压完成，路径: $extracted_dir"

  # 创建符号链接
  local base_dir="$INSTALL_DIR/jdk-$version"
  if [ -L "$base_dir" ]; then
      echo "符号链接 $base_dir 已存在，将被覆盖。"
  fi
  ln -sf "$extracted_dir" "$base_dir"
}

# 安装 Java
function install_java() {
  local version=$1
  # 根据操作系统选择合适的JDK版本
  local url
  # 根据操作系统选择合适的JDK版本
  if [[ "$(uname)" == "Darwin" ]]; then
    # 尝试使用macOS专用版本
    url=${MAC_JAVA_INFO[$version]}
  fi
  
  # 如果没有找到macOS版本或不在macOS上，则使用默认Linux版本
  if [ -z "$url" ]; then
    url=${JAVA_INFO[$version]}
  fi

  if [ -z "$url" ]; then
    echo "不支持的 Java 版本: $version"
    echo "支持的版本: ${!JAVA_INFO[@]}"
    exit 1
  fi

  local base_dir="$INSTALL_DIR/jdk-$version"
  local java_home_path="$base_dir"

  if [[ "$(uname)" == "Darwin" ]] && [ -d "$base_dir/Contents/Home" ]; then
    java_home_path="$base_dir/Contents/Home"
  fi

  # 如果已经存在，则跳过
  if [ -d "$base_dir" ]; then
    echo "Java $version 已经安装。"
    set_environment_variables "$base_dir"
    return
  fi

  download_and_extract "$url" "$version"
  set_environment_variables "$base_dir"
}

# 主函数
function main() {
  check_permissions
  check_arguments "$@"

  local version=${1:-11}
  local custom_install_dir=${2}

  if [ -n "$custom_install_dir" ]; then
    INSTALL_DIR="$custom_install_dir"
  fi

  install_java "$version"
  switch_java "$version"

  echo "Java 安装完成。"
  java -version
}

main "$@"