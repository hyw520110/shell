#!/bin/bash

set -euo pipefail

# 设置默认OpenCV版本
export OPENCV_VERSION="${OPENCV_VERSION:-4.11.0}"
# 设置默认安装路径  
INSTALL_PATH="/usr/local"
# 是否启用扩展模块  
ENABLE_CONTRIB=true  
# 是否启用Java支持
ENABLE_JAVA=true  
# 是否启用ccache加速编译
CCACHE_ENABLE=true  
# 是否禁用非必要模块
DISABLE_UNUSED=ON
# 是否强制安装
FORCE_INSTALL=false

: ${JAVA_HOME:=/opt/Java/dragonwell-11.0.22.19+7-ga}  # 设置默认JAVA_HOME
export JAVA_HOME
OS_TYPE=$(uname -s) 
# 根据操作系统设置Java库扩展名
if [ "$OS_TYPE" = "Darwin" ]; then
    JAVA_LIB_EXT="dylib"
else
    JAVA_LIB_EXT="so"
fi

while getopts ":v:p:cjhf" opt; do
  case $opt in
    v) OPENCV_VERSION="$OPTARG" ;;  
    p) INSTALL_PATH="$OPTARG" ;;  
    c) ENABLE_CONTRIB=true ;;  
    j) ENABLE_JAVA=true ;;  
    f) FORCE_INSTALL=true ;; 
    h) echo "$USAGE"; exit 0 ;;  
    \?) die "无效选项: -$OPTARG" ;; 
  esac
done

# 检测系统包管理器
case "$OS_TYPE" in
    Linux) 
        for mgr in apt dnf yum pacman; do
            if command -v $mgr &>/dev/null; then
                PKG_MGR="$mgr"
                break
            fi
        done
        [ -n "$PKG_MGR" ] || die "❌ 未检测到支持的Linux包管理器"
        ;; 
    Darwin) 
        command -v brew &>/dev/null || die "❌ 请先安装Homebrew: https://brew.sh"
        PKG_MGR="brew"
        ;; 
    *) die "❌ 不支持的操作系统: $OS_TYPE" ;; 
esac
export PKG_MGR

# 🛠️ 函数：打印信息并退出
die() { echo "$*" >&2; exit 1; }
warn() { echo "$*" >&2; }

# 🔧 错误处理函数
handle_error() {
    local exit_code=$?
    local last_cmd="${BASH_COMMAND:-unknown}"
    echo -e "\n❌ 在 ${BASH_SOURCE[0]}:${BASH_LINENO[-1]} 发生错误"
    echo "执行命令: $last_cmd"
    exit $exit_code
}
# 🛠️ 执行命令并显示进度
run_cmd() {
    local show_output=true
    if [[ "$1" == "--verbose" ]]; then
        show_output=true
        shift
    fi

    echo "🏃 执行: $*"
    if [[ "$show_output" == true ]]; then
        "$@" # 直接执行，显示实时输出
        return $?
    fi

    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    
    # 将命令的输出重定向到临时文件
    local tmp_log=$(mktemp)
    "$@" &> "$tmp_log" &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r${spin[$i]} 运行中..."
        sleep 0.1
    done

    wait $pid
    local status=$?
    if [ $status -ne 0 ]; then
        printf "\r❌ 命令执行失败（退出码: $status）\n"
        # 失败时打印日志
        cat "$tmp_log"
    fi
    rm -f "$tmp_log"
    return $status
}

# 🔍 安装验证函数
verify_installation() {
    echo "🔍 验证安装结果..."
    # 检查核心库文件
    local lib_path="${INSTALL_PATH}"
    if [ ! -d "$lib_path" ]; then
        die "安装目录不存在: $lib_path"
    fi
	echo "OS_TYPE:$OS_TYPE JAVA_LIB_EXT:$JAVA_LIB_EXT"
    # 检查Java绑定
    if [[ "$ENABLE_JAVA" == true ]]; then
        local java_lib=$(find "$lib_path" -name "libopencv_java*.${JAVA_LIB_EXT}" 2>/dev/null | head -1)
        if [ -n "$java_lib" ]; then
            echo "✅ 找到Java动态库: $java_lib"
        else
            warn "⚠️ 未找到Java动态库，可能未启用Java支持"
        fi
    fi

    # 版本验证
    if command -v pkg-config &>/dev/null; then
        local installed_ver=$(pkg-config --modversion opencv4)
        echo "📦 已安装版本: ${installed_ver:-未知}"
    else
        warn "⚠️ pkg-config不可用，无法验证版本"
    fi
}

# 🔄 提权后环境变量保持机制
preserve_env_vars() {
    # 需要保留的环境变量列表（添加对JAVA_HOME的特殊处理）
    local preserved_vars=(
        JAVA_HOME
        OPENCV_VERSION
        INSTALL_PATH
        OPENCV_VERSION
        ENABLE_CONTRIB
        ENABLE_JAVA
    )
    local var_str=""
    for var in "${preserved_vars[@]}"; do
        if [ -n "${!var:-}" ]; then
            printf -v var_str "%s%s=%q " "$var_str" "$var" "${!var}"
        fi
    done
    
    echo "$var_str"
}

# 🛡️ 提权检查与执行
check_sudo() {
	export ORIGINAL_USER=${SUDO_USER:-$(whoami)}
    if [ "$(id -u)" -ne 0 ]; then
        echo "⚠️ 需要管理员权限，尝试提权..."
        local preserved_env=$(preserve_env_vars)
        #echo "传递的环境变量: ${preserved_env}"
        exec sudo --preserve-env=OS_TYPE,JAVA_HOME,INSTALL_PATH,OPENCV_VERSION,ENABLE_CONTRIB,ENABLE_JAVA "$0" "$@"
        exit $?
    fi
}

# 🛠️ 检查并获取 JAVA_HOME
check_java_home() {
	if [ -n "${JAVA_HOME:-}" ]; then
        #echo "ℹ️ 使用预设 JAVA_HOME: $JAVA_HOME"
        [ -f "${JAVA_HOME}/include/jni.h" ] && return 0
    fi
    warn "⚠️ 预设的JAVA_HOME无效，将尝试自动检测"
    local java_paths=(
        "$(dirname $(dirname $(command -v javac 2>/dev/null)))" 
        "$(dirname $(dirname $(command -v java 2>/dev/null)))" 
        "/usr/lib/jvm/java-11-openjdk-amd64"     
        "/usr/local/java"
        "/Library/Java/JavaVirtualMachines/*/Contents/Home"                    
    )
	for path in "${java_paths[@]}"; do
	 	# 展开通配符
        for expanded_path in $path;
        do
        	if [ -f "${expanded_path}/include/jni.h" ]; then
            	JAVA_HOME="$expanded_path" && export JAVA_HOME
            	echo "✅ 检测到有效 JAVA_HOME: $JAVA_HOME"
            	return 0
        	fi
        done
    done
    die "❌ 无法定位有效JDK路径"
}

# 标记已安装的可选依赖
INSTALLED_OPTIONAL_DEPS_STRING=":"

# 检查并安装依赖的辅助函数
_install_dependencies() {
    local deps_to_check=($@)
    local missing_deps=()

    for dep in "${deps_to_check[@]}"; do
        case "$PKG_MGR" in
            apt)    ! (dpkg -l | grep -q "^ii  $dep" || command -v "$dep" &>/dev/null) && missing_deps+=("$dep") ;; 
            brew)   ! (brew list "$dep" &>/dev/null || command -v "$dep" &>/dev/null) && missing_optional_deps+=("$dep") ;; 
            dnf|yum) ! rpm -q "$dep" &>/dev/null && missing_deps+=("$dep") ;; 
            pacman) ! pacman -Qi "$dep" &>/dev/null && missing_deps+=("$dep") ;; 
        esac
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "⬇️ 安装依赖: ${missing_deps[*]}"
        case "$PKG_MGR" in
            apt)    run_cmd sudo apt-get install -y "${missing_deps[@]}" ;; 
            brew) 
                if [ "$(id -u)" -eq 0 ]; then
                    run_cmd sudo -u "$ORIGINAL_USER" brew install  "${missing_deps[@]}"
                else
                    run_cmd brew install --force-bottle "${missing_deps[@]}"
                fi
                ;; 
            dnf)    run_cmd sudo dnf install -y "${missing_deps[@]}" ;; 
            yum)    run_cmd sudo yum install -y "${missing_deps[@]}" ;; 
            pacman) run_cmd sudo pacman -Sy --noconfirm "${missing_deps[@]}" ;; 
        esac
    fi
}

# 📦 智能依赖安装
install_deps() {
    echo "🔍 检测系统并安装依赖..."
    local required_deps=()
    local optional_deps=()

    case "$PKG_MGR" in
        apt)
            required_deps=(build-essential cmake git libjpeg-dev libpng-dev libtiff-dev zlib1g-dev libavcodec-dev libavformat-dev libswscale-dev libv4l-dev libxvidcore-dev libx264-dev libopenblas-dev libatlas-base-dev gfortran python3-dev python3-numpy libgtk-3-dev libtbb-dev)
            optional_deps=(libeigen3-dev ccache ant)
            run_cmd sudo apt-get update
            ;; 
        brew)
            required_deps=(cmake git jpeg libpng libtiff zlib ffmpeg tbb)
            optional_deps=(eigen ccache ant)
            run_cmd sudo -u "$ORIGINAL_USER" brew update
            ;; 
        dnf)
            required_deps=(@development-tools cmake git libjpeg-turbo-devel libpng-devel libtiff-devel zlib-devel ffmpeg-devel x264-devel openblas-devel gfortran python3-devel numpy gtk3-devel tbb-devel)
            optional_deps=(eigen3-devel ccache ant)
            run_cmd sudo dnf groupinstall -y "Development Tools"
            ;; 
        yum)
            required_deps=(gcc-c++ make cmake git libjpeg-turbo-devel libpng-devel libtiff-devel zlib-devel ffmpeg-devel x264-devel openblas-devel gcc-fortran python3-devel numpy gtk3-devel tbb-devel)
            optional_deps=(eigen3-devel ccache ant)
            run_cmd sudo yum groupinstall -y "Development Tools"
            ;; 
        pacman)
            required_deps=(base-devel cmake git libjpeg libpng libtiff zlib ffmpeg x264 openblas gcc-fortran python numpy gtk3 tbb)
            optional_deps=(eigen ccache ant)
            ;; 
        *) die "❌ 不支持的包管理器: $PKG_MGR" ;; 
    esac

    echo "--- 检查必需依赖 ---"
    _install_dependencies "${required_deps[@]}"
    echo "✅ 必需依赖已满足"

    local missing_optional_deps=()
    for dep in "${optional_deps[@]}"; do
        case "$PKG_MGR" in
            apt)    ! (dpkg -l | grep -q "^ii  $dep" || command -v "$dep" &>/dev/null) && missing_optional_deps+=("$dep") ;; 
            brew)   ! (brew list "$dep" &>/dev/null || command -v "$dep" &>/dev/null) && missing_optional_deps+=("$dep") ;; 
            dnf|yum) ! rpm -q "$dep" &>/dev/null && missing_optional_deps+=("$dep") ;; 
            pacman) ! pacman -Qi "$dep" &>/dev/null && missing_optional_deps+=("$dep") ;; 
        esac
    done

    if [ ${#missing_optional_deps[@]} -gt 0 ]; then
        echo "⬇️ 发现未安装的可选依赖: ${missing_optional_deps[*]}"
        echo "   - ccache: 加速重复编译"
        echo "   - eigen: 优化部分数学运算"
        echo "   - ant: 构建Java绑定"
        read -t 5 -p "❓ 是否安装可选依赖? (y/N) [5秒后自动跳过]: " choice || true
        echo ""
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            _install_dependencies "${missing_optional_deps[@]}"
        else
            echo "⏭️ 已跳过安装可选依赖。"
        fi
    fi

    # 记录最终安装了哪些可选依赖
    INSTALLED_OPTIONAL_DEPS_STRING=":"
    for dep in "${optional_deps[@]}"; do
        local dep_name=${dep%%-*}
        if command -v "$dep_name" &>/dev/null || brew list "$dep_name" &>/dev/null 2>&1; then
            INSTALLED_OPTIONAL_DEPS_STRING=":${INSTALLED_OPTIONAL_DEPS_STRING}${dep_name}:"
        fi
    done
}

# 📥 源码下载
download_opencv() {
    local repo_url="https://github.com/opencv/opencv.git"
    local contrib_repo="https://github.com/opencv/opencv_contrib.git"
    if [ ! -d "opencv" ]; then
        echo "📥 克隆OpenCV仓库版本: $OPENCV_VERSION ..."
        run_cmd git clone --depth 1 --branch "$OPENCV_VERSION"  "${repo_url}" opencv
    fi
    cd opencv 
    if [[ "$ENABLE_CONTRIB" == true ]]; then
        if [ ! -d "opencv_contrib" ]; then
            echo "📥 克隆Contrib模块..."
            run_cmd git clone --depth 1 --branch "$OPENCV_VERSION" "${contrib_repo}" opencv_contrib
        fi
    fi
}

# 🔧 智能CMake配置
generate_cmake_config() {
    local cmake_args=(
        -D CMAKE_BUILD_TYPE=RELEASE
        -D CMAKE_INSTALL_PREFIX="${INSTALL_PATH}"
        -D BUILD_EXAMPLES=OFF
        -D BUILD_PERF_TESTS=OFF
        -D BUILD_TESTS=OFF
        -D WITH_IPP=OFF
        -D OPENCV_GENERATE_PKGCONFIG=ON
        -D WITH_OPENMP=OFF
        -D WITH_FFMPEG=ON
        -D WITH_OPENBLAS=OFF
        -D WITH_LAPACK=OFF
        -D WITH_ACCELERATE=ON
        -D WITH_OPENCL=ON
        -D ENABLE_FAST_MATH=ON
        -D BUILD_opencv_world=OFF 
        -D WITH_PROTOBUF=OFF
    )

    # 根据已安装的可选依赖动态添加配置
    if [[ ":$INSTALLED_OPTIONAL_DEPS_STRING:" == *":ccache:"* && "$CCACHE_ENABLE" == true ]]; then
        cmake_args+=("-D CMAKE_CXX_COMPILER_LAUNCHER=ccache")
    fi
    if [[ ":$INSTALLED_OPTIONAL_DEPS_STRING:" == *":eigen:"* ]]; then
        cmake_args+=(-D WITH_EIGEN=ON)
    else
        cmake_args+=(-D WITH_EIGEN=OFF)
    fi

	[[ "$DISABLE_UNUSED" == ON ]] && cmake_args+=(
        -D WITH_GTK=OFF
        -D WITH_VTK=OFF
        -D WITH_MATLAB=OFF
        -D WITH_CUDA=OFF
        -D WITH_OPENGL=OFF
        -D CMAKE_CXX_FLAGS="-march=native -O3"
        -D CMAKE_C_FLAGS="-march=native -O3"
    )
    [[ "$ENABLE_CONTRIB" == true ]] && cmake_args+=(
        -D OPENCV_EXTRA_MODULES_PATH=../opencv_contrib/modules
    )
  	if [[ "$ENABLE_JAVA" == true ]]; then
        check_java_home
        if [[ ":$INSTALLED_OPTIONAL_DEPS_STRING:" != *":ant:"* ]]; then
            warn "⚠️ 未安装ant，无法构建Java绑定，将跳过。"
        else
            case "$OS_TYPE" in
            Linux)
                JAVA_INCLUDE_SUBPATH="linux"
                ;; 
            Darwin)
                JAVA_INCLUDE_SUBPATH="darwin"
                ;; 
            esac
            cmake_args+=(
                -D BUILD_opencv_java=ON
                -D ANT_EXECUTABLE="$(which ant)"
                -D JAVA_AWT_INCLUDE_PATH="${JAVA_HOME}/include"
                -D JAVA_AWT_LIBRARY="${JAVA_HOME}/lib"
                -D JAVA_INCLUDE_PATH2="${JAVA_HOME}/include/${JAVA_INCLUDE_SUBPATH}"
            )
            [ -f "${JAVA_HOME}/include/jni.h" ] || die "缺失Java头文件jni.h"
        fi
    fi

    command -v brew &>/dev/null && cmake_args+=(
        -D WITH_QUICKTIME=OFF
        -D WITH_AVFOUNDATION=ON
        -D WITH_OPENBLAS=OFF
        -D WITH_LAPACK=OFF
        -D WITH_ACCELERATE=ON
    )
    echo "⚙️ CMake配置参数: ${cmake_args[*]}"
    run_cmd cmake "${cmake_args[@]}" ../
}
get_memory_gb() {
    case "$OS_TYPE" in
        Linux) free -g | awk '/Mem:/{print $2}' ;; 
        Darwin) sysctl -n hw.memsize | awk '{print int($0/1024^3)}' ;; 
        *) echo 8 ;; 
    esac
}
get_cpu_cores() {
    case "$(uname -s)" in
        Linux) nproc ;; 
        Darwin) sysctl -n hw.ncpu ;; 
        *) echo 4 ;; 
    esac
}
main() {
    trap handle_error ERR
    echo "🚀 开始安装OpenCV ..."
    # 设置重入标记（防止在sudo重入时跳过安装检查）
    _REENTRY_GUARD=${_REENTRY_GUARD:-0}
    check_sudo "$@"
    _REENTRY_GUARD=1   # 设置标记，避免后续重入时跳过安装检查

     # 检查是否已安装
    if [[ "$FORCE_INSTALL" == false ]] && [[ -f "${INSTALL_PATH}/lib/pkgconfig/opencv4.pc" ]]; then
            echo "✅ OpenCV 已安装，跳过安装流程。使用 -f 强制重新安装。"
            verify_installation
            exit 0
    fi
    check_java_home
    echo "🕒 预计安装时间：10-30分钟（取决于网络和硬件）"
    # 环境准备
    install_deps
    download_opencv
    
    # 编译安装
    local build_dir="build-${OPENCV_VERSION//./_}"
    if [ -d "$build_dir" ]; then
        echo "♻️ 复用已有编译目录..."
        cd "$build_dir"
    else
        mkdir -p "$build_dir" && cd "$build_dir"
        generate_cmake_config  
    fi
    MEM_GB=$(get_memory_gb)
    SAFE_CORES=$(( MEM_GB / 2 ))
    CPU_CORES=$(get_cpu_cores)
    PARALLEL_JOBS=$(( SAFE_CORES > CPU_CORES ? CPU_CORES : SAFE_CORES ))
    PARALLEL_JOBS=$(( PARALLEL_JOBS > 0 ? PARALLEL_JOBS : 2 ))
    # 如果内存小于2GB，则使用1个线程
    if [ $MEM_GB -lt 2 ]; then
        PARALLEL_JOBS=2
    fi
    echo "💻 内存: ${MEM_GB}GB, 逻辑CPU核心: ${CPU_CORES}, 使用并行编译线程数: ${PARALLEL_JOBS}"

    # 根据CMake版本修改OpenCVGenPkgconfig.cmake
    version=$(cmake --version 2>/dev/null|grep version|awk '{print $3}'| cut -d. -f1)
    if [[ $version  -gt 3 ]]; then
        local cmake_file="../cmake/OpenCVGenPkgconfig.cmake"
        if [ -f "$cmake_file" ]; then
            echo "🛠️ 修改 $cmake_file 中的CMake最低版本要求..."
            if [ "$OS_TYPE" = "Darwin" ]; then
                sed -i '' 's/cmake_minimum_required(VERSION 2.8.12.2)/cmake_minimum_required(VERSION 3.5)/g' "$cmake_file"
            else
                sed -i 's/cmake_minimum_required(VERSION 2.8.12.2)/cmake_minimum_required(VERSION 3.5)/g' "$cmake_file"
            fi
        fi
    fi

    echo "🏗️ 开始编译（使用${PARALLEL_JOBS}线程并行编译加速）..."
    make_path=$(which make)
    run_cmd --verbose $make_path -j$PARALLEL_JOBS || exit 1
	echo "📦 开始安装..." 
	run_cmd --verbose sudo $make_path install || exit 1
    echo "🔄 更新动态链接库缓存..."
    case "$OS_TYPE" in
        Linux) run_cmd sudo ldconfig ;; 
        Darwin) run_cmd sudo update_dyld_shared_cache ;; 
    esac

    echo "🎉 安装成功！验证安装："
    verify_installation

}

main "$@"