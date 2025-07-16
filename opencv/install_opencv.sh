#!/bin/bash

set -euo pipefail

# 设置默认OpenCV版本
OPENCV_VERSION="${OPENCV_VERSION:-4.11.0}"
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

: ${JAVA_HOME:=/opt/Java/dragonwell-11.0.22.19+7-ga}  # 设置默认JAVA_HOME
export JAVA_HOME
OS_TYPE=$(uname -s) 

while getopts ":v:p:cjh" opt; do
  case $opt in
    v) OPENCV_VERSION="$OPTARG" ;;  
    p) INSTALL_PATH="$OPTARG" ;;  
    c) ENABLE_CONTRIB=true ;;  
    j) ENABLE_JAVA=true ;;  
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
# 执行命令
run_cmd() {
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    echo "🏃 执行: $*"
    "$@" &
    local pid=$!

    while kill -0 $pid &>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r${spin[$i]} 运行中..."
        sleep 0.1
    done

    if ! wait $pid; then
        local status=$?
        printf "\r❌ 命令执行失败（退出码: %d）\n" "$status"
        return $status
    fi

    local status=$?
    printf "\r✅ 命令执行完成（退出码: %d）\n" "$status"
    return $status
}


# 🛠️ 执行命令并显示进度
run_cmd() {
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    echo "🏃 执行: $*"
    "$@" &
    local pid=$!
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r${spin[$i]} 运行中..."
        sleep 0.1
    done
    
    wait $pid
    local status=$?  # 直接获取 wait 的返回值
    printf "\r✅ 命令执行完成（退出码: $status）\n"
    return $status
}
# 🔍 安装验证函数
verify_installation() {
    echo "🔍 验证安装结果..."
    # 检查核心库文件
    local lib_path="${INSTALL_PATH}/lib"
    if [ ! -d "$lib_path" ]; then
        die "安装目录不存在: $lib_path"
    fi
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
        exec sudo --preserve-env=JAVA_HOME,INSTALL_PATH,OPENCV_VERSION,ENABLE_CONTRIB,ENABLE_JAVA "$0" "$@"
        exit $?
    fi
}

# 🛠️ 检查并获取 JAVA_HOME
check_java_home() {
	if [ -n "${JAVA_HOME:-}" ]; then
        #echo "ℹ️ 使用预设 JAVA_HOME: $JAVA_HOME"
        [ -f "${JAVA_HOME}/include/jni.h" ] && return 0
    fi
    local java_paths=(
        "$(echo $(command -v javac 2>/dev/null | sed 's|/bin/javac||'))"
        "$(readlink -f $(command -v java 2>/dev/null | sed 's|/bin/java||'))"
        "/usr/lib/jvm/java-11-openjdk-amd64"     
        "/usr/local/java"                        
    )
	for path in "${java_paths[@]}"; do
        if [ -f "${path}/include/jni.h" ]; then
            JAVA_HOME="$path"
            echo "✅ 检测到有效 JAVA_HOME: $JAVA_HOME"
            return 0
        fi
    done
    die "❌ 无法定位有效JDK路径"
}

# 📦 智能依赖安装
install_deps() {
    echo "🔍 检测系统并安装依赖..."
    case "$PKG_MGR" in
        apt)
            common_deps=(
                build-essential cmake git libjpeg-dev libpng-dev libtiff-dev
                zlib1g-dev libavcodec-dev libavformat-dev libswscale-dev
                libv4l-dev libxvidcore-dev libx264-dev libopenblas-dev
                libatlas-base-dev gfortran python3-dev python3-numpy
                libgtk-3-dev libtbb-dev libeigen3-dev
            )
            ;;
        brew)
            common_deps=(cmake git jpeg libpng libtiff zlib ffmpeg openblas eigen tbb)
            ;;
        dnf)
            common_deps=(
                @development-tools cmake git libjpeg-turbo-devel libpng-devel
                libtiff-devel zlib-devel ffmpeg-devel x264-devel openblas-devel
                gfortran python3-devel numpy gtk3-devel tbb-devel eigen3-devel
            )
            ;;
        yum)
            common_deps=(
                gcc-c++ make cmake git libjpeg-turbo-devel libpng-devel
                libtiff-devel zlib-devel ffmpeg-devel x264-devel
                openblas-devel gcc-fortran python3-devel numpy gtk3-devel
                tbb-devel eigen3-devel
            )
            ;;
        pacman)
            common_deps=(
                base-devel cmake git libjpeg libpng libtiff zlib ffmpeg x264
                openblas gcc-fortran python numpy gtk3 tbb eigen
            )
            ;;
        *) die "❌ 不支持的包管理器: $PKG_MGR" ;;
    esac
    # 检查ccache安装
    if [[ "$CCACHE_ENABLE" == true ]] && ! command -v ccache &>/dev/null; then
       echo "🔧 安装ccache加速编译..."
       run_cmd $PKG_MGR install ccache 
    fi
    local missing_deps=()
    for dep in ${common_deps}; do
        case "$PKG_MGR" in
            apt) dpkg -l | grep -q "^ii  $dep" || missing_deps+=("$dep") ;;
<<<<<<< HEAD
            brew) (brew list $dep &>/dev/null && command -v $dep &>/dev/null) || missing_deps+=("$dep") ;;
=======
            brew)
                if ! command -v "$dep" &>/dev/null; then
                      brew list "$dep" &>/dev/null || missing_deps+=("$dep")
                fi
                ;;
>>>>>>> 3dc09231f2b8e89d76696716181791ad786a8ee8
            dnf|yum) rpm -q $dep &>/dev/null || missing_deps+=("$dep") ;;
            pacman) pacman -Qi $dep &>/dev/null || missing_deps+=("$dep") ;;
        esac
    done
  
    if [ ${#missing_deps[@]} -eq 0 ]; then
        echo "✅ 所有依赖已安装"
        return ;
    fi
    echo "📦 安装缺失依赖: ${missing_deps[*]}"
    case "$PKG_MGR" in
        apt)
            run_cmd sudo apt update
            run_cmd sudo apt install -y "${missing_deps[@]}"
            ;;
        brew)
            if [ "$(id -u)" -eq 0 ]; then
                echo "🔒 以用户 $ORIGINAL_USER 执行 Homebrew 安装..."
                run_cmd sudo -u "$ORIGINAL_USER" brew install "${missing_deps[@]}"
                run_cmd sudo -u "$ORIGINAL_USER" brew link --overwrite openblas
            else
                run_cmd brew install "${missing_deps[@]}"
                run_cmd brew link --overwrite openblas
            fi
            ;;
        esac

}

# 📥 源码下载
download_opencv() {
    local repo_url="git@github.com:opencv/opencv.git"
    local contrib_repo="git@github.com:opencv/opencv_contrib.git"
    
    if [ ! -d "opencv" ]; then
        echo "📥 克隆OpenCV仓库（版本: $OPENCV_VERSION）..."
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
        -D BUILD_EXAMPLES=OFF			   # 🔥关闭示例编译
        -D BUILD_PERF_TESTS=OFF                # 🔥关闭性能测试
        -D BUILD_TESTS=OFF                     # 🔥关闭单元测试
        -D BUILD_opencv_perf_calib3d=OFF	   # 显式禁用所有性能测试子模块
        -D BUILD_opencv_perf_dnn=OFF
        -D BUILD_opencv_perf_features2d=OFF
        -D BUILD_opencv_perf_imgcodecs=OFF
        -D BUILD_opencv_perf_objdetect=OFF
        -D BUILD_opencv_perf_photo=OFF
        -D BUILD_opencv_perf_video=OFF
        -D WITH_IPP=OFF                        # 🔥关闭IPP加速
        -D CMAKE_CXX_COMPILER_LAUNCHER=ccache  # 🔥启用编译缓存
        -D OPENCV_GENERATE_PKGCONFIG=ON
        -D WITH_OPENMP=ON
        -D WITH_FFMPEG=ON
        -D WITH_OPENCL=ON
        -D ENABLE_FAST_MATH=ON
        -DWITH_PKGCONFIG=OFF
        -DOPENCV_GENERATE_PKGCONFIG=OF
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        -D CMAKE_CXX_STANDARD=17 
        -D CMAKE_CXX_STANDARD_REQUIRED=ON 
        -D CMAKE_CXX_EXTENSIONS=OFF
        -D CMAKE_CXX_FLAGS="-std=c++14 -march=native -O3"
        -D BUILD_opencv_world=OFF 
        -D WITH_PROTOBUF=OFF
    )
	[[ "$DISABLE_UNUSED" == ON ]] && cmake_args+=(
        -D WITH_GTK=OFF
        -D WITH_VTK=OFF
        -D WITH_MATLAB=OFF
        -D WITH_CUDA=OFF          # 禁用CUDA加速
        -D WITH_EIGEN=OFF         # 禁用Eigen
        -D WITH_OPENGL=OFF
        -D CMAKE_CXX_FLAGS="-march=native -O3"   # 启用编译器优化
        -D CMAKE_C_FLAGS="-march=native -O3"
    )
    [[ "$ENABLE_CONTRIB" == true ]] && cmake_args+=(
        -D OPENCV_EXTRA_MODULES_PATH=../opencv_contrib/modules
    )
  	if [[ "$ENABLE_JAVA" == true ]]; then
        check_java_home
        case "$OS_TYPE" in
        Linux)
            run_cmd sudo apt install -y ant
            JAVA_INCLUDE_SUBPATH="linux"
            JAVA_LIB_EXT="so"
            ;;
        Darwin)
             if ! command -v ant &>/dev/null; then
                brew list ant &>/dev/null || run_cmd brew install ant
             fi
            JAVA_INCLUDE_SUBPATH="darwin"
            JAVA_LIB_EXT="dylib"
            ;;
    	esac
        cmake_args+=(
        -D JAVA_INCLUDE_PATH2="${JAVA_HOME}/include/${JAVA_INCLUDE_SUBPATH}"
        -D ANT_EXECUTABLE="$(which ant)"
        -D BUILD_opencv_java=ON
        -D JAVA_AWT_INCLUDE_PATH="${JAVA_HOME}/include"
        -D JAVA_AWT_LIBRARY="${JAVA_HOME}/lib"
	    )
	    [ -f "${JAVA_HOME}/include/jni.h" ] || die "缺失Java头文件jni.h"
    fi

    command -v brew &>/dev/null && cmake_args+=(
        -D WITH_QUICKTIME=OFF
        -D WITH_AVFOUNDATION=ON
    )
    #echo "⚙️ CMake配置参数: ${cmake_args[*]}"
    run_cmd cmake "${cmake_args[@]}" ../
}
get_memory_gb() {
    case "$OS_TYPE" in
        Linux) free -g | awk '/Mem:/{print $2}' ;;
        Darwin) sysctl -n hw.memsize | awk '{print int($0/1024^3)}' ;;
        *) echo 8 ;; 
<<<<<<< HEAD
=======
    esac
}
get_cpu_cores() {
    case "$(uname -s)" in
        Linux) nproc ;;
        Darwin) sysctl -n hw.ncpu ;;
        *) echo 4 ;;  # 默认 4 核
>>>>>>> 3dc09231f2b8e89d76696716181791ad786a8ee8
    esac
}
main() {
    trap handle_error ERR
    echo "🚀 开始安装OpenCV ..."
    check_sudo "$@"
    # 检查是否已安装
    _REENTRY_GUARD=1  
    #if [[ -f "${INSTALL_PATH}/lib/pkgconfig/opencv4.pc" ]]; then
    if command -v pkg-config &> /dev/null && pkg-config --modversion opencv4 &> /dev/null; then
        if [ -z "${_REENTRY_GUARD:-}" ]; then
            echo "✅ OpenCV 已安装，跳过安装流程。"
            verify_installation
            exit 0
        fi
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
        generate_cmake_config  # 仅在首次生成配置
    fi
    MEM_GB=$(get_memory_gb)
    SAFE_CORES=$(( MEM_GB / 2 ))
    CPU_CORES=$(get_cpu_cores)
    PARALLEL_JOBS=$(( SAFE_CORES > CPU_CORES ? CPU_CORES : SAFE_CORES ))
    PARALLEL_JOBS=$(( PARALLEL_JOBS > 0 ? PARALLEL_JOBS : 2 ))
    version=$(cmake --version 2>/dev/null|grep version|awk '{print $3}'| cut -d. -f1)
    if [[ $version  -gt 3 ]]; then
	    sed -i '' 's/cmake_minimum_required(VERSION 2.8.12.2)/cmake_minimum_required(VERSION 3.5)/g' ../cmake/OpenCVGenPkgconfig.cmake
    fi

    echo "🏗️ 开始编译（使用${PARALLEL_JOBS}线程并行编译加速）..."
    make_path=$(which make)
    run_cmd $make_path -j$PARALLEL_JOBS || exit 1
	echo "📦 开始安装..." 
	run_cmd sudo $make_path install || exit 1
    echo "🔄 更新动态链接库缓存..."
    case "$OS_TYPE" in
        Linux) run_cmd sudo ldconfig ;;
        Darwin) run_cmd sudo update_dyld_shared_cache ;;
    esac
    
    echo "🎉 安装成功！验证安装："
    pkg-config --modversion opencv4
    
}

main "$@"