#!/bin/bash
# beyond4.sh - Beyond Compare 4 破解脚本
# 用途: 移除Beyond Compare 4的试用限制
# 参数: 无

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否以root权限运行
is_root() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# 使用sudo执行命令
exec_sudo() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

# 查找BCompare文件位置
find_bcompare_dir() {
    local dir=""
    
    # 常见安装路径
    local paths=(
        "/usr/lib/beyondcompare"
        "/opt/apps/com.scootersoftware.bcompare/files"
        "/var/lib/linglong/layers"
    )
    
    for path in "${paths[@]}"; do
        if [ -d "$path" ] && [ -f "$path/BCompare" ]; then
            echo "$path"
            return 0
        fi
    done
    
    # 如果在常见路径中未找到，则全局搜索
    echo_info "在常见路径中未找到 BCompare，正在全局搜索..."
    dir=$(exec_sudo find / -name BCompare 2>/dev/null | head -1 | dirname)
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        echo "$dir"
        return 0
    fi
    
    return 1
}

# 主函数
main() {
    echo_info "开始破解 Beyond Compare 4..."
    
    # 步骤1: 修改BCompare文件
    echo_step "步骤1: 修改BCompare文件"
    
    # 删除注册表数据
    if [ -f ~/.config/bcompare/registry.dat ]; then
        echo_info "删除 registry.dat..."
        rm -rf ~/.config/bcompare/registry.dat

    fi
    [ -d ~/.config/bcomapre ] && rm -rf ~/.config/bcomapre
    # 查找BCompare文件位置
    dir=$(find_bcompare_dir)
    if [ $? -ne 0 ] || [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo_error "未找到 BCompare 目录"
        exit 1
    fi

    echo_info "BCompare 目录: $dir"
    
    # 检查BCompare文件是否存在
    if [ ! -f "$dir/BCompare" ]; then
        echo_error "未找到 BCompare 文件"
        exit 1
    fi
    
    # 备份原文件
    echo_info "备份 BCompare 文件..."
    exec_sudo cp "$dir/BCompare" "$dir/BCompare.backup"
    
    # 修改文件
    echo_info "执行sed命令修改 BCompare 文件..."
    exec_sudo sed -i "s/keexjEP3t4Mue23hrnuPtY4TdcsqNiJL-5174TsUdLmJSIXKfG2NGPwBL6vnRPddT7tH29qpkneX63DO9ECSPE9rzY1zhThHERg8lHM9IBFT+rVuiY823aQJuqzxCKIE1bcDqM4wgW01FH6oCBP1G4ub01xmb4BGSUG6ZrjxWHJyNLyIlGvOhoY2HAYzEtzYGwxFZn2JZ66o4RONkXjX0DF9EzsdUef3UAS+JQ+fCYReLawdjEe6tXCv88GKaaPKWxCeaUL9PejICQgRQOLGOZtZQkLgAelrOtehxz5ANOOqCaJgy2mJLQVLM5SJ9Dli909c5ybvEhVmIC0dc9dWH+/N9KmiLVlKMU7RJqnE+WXEEPI1SgglmfmLc1yVH7dqBb9ehOoKG9UE+HAE1YvH1XX2XVGeEqYUY-Tsk7YBTz0WpSpoYyPgx6Iki5KLtQ5G-aKP9eysnkuOAkrvHU8bLbGtZteGwJarev03PhfCioJL4OSqsmQGEvDbHFEbNl1qJtdwEriR+VNZts9vNNLk7UGfeNwIiqpxjk4Mn09nmSd8FhM4ifvcaIbNCRoMPGl6KU12iseSe+w+1kFsLhX+OhQM8WXcWV10cGqBzQE9OqOLUcg9n0krrR3KrohstS9smTwEx9olyLYppvC0p5i7dAx2deWvM1ZxKNs0BvcXGukR+/g" "$dir/BCompare"

    # 步骤2: 创建密钥文件
    echo_step "步骤2: 创建密钥文件"
    echo_info "创建BC4Key.txt密钥文件..."
    
    # 创建密钥内容
    cat > /tmp/BC4Key.txt << 'EOF'
GXN1eh9FbDiX1ACdd7XKMV7hL7x0ClBJLUJ-zFfKofjaj2yxE53xauIfkqZ8FoLpcZ0Ux6McTyNmODDSvSIHLYhg1QkTxjCeSCk6ARz0ABJcnUmd3dZYJNWFyJun14rmGByRnVPL49QH+Rs0kjRGKCB-cb8IT4Gf0Ue9WMQ1A6t31MO9jmjoYUeoUmbeAQSofvuK8GN1rLRv7WXfUJ0uyvYlGLqzq1ZoJAJDyo0Kdr4ThF-IXcv2cxVyWVW1SaMq8GFosDEGThnY7C-SgNXW30jqAOgiRjKKRX9RuNeDMFqgP2cuf0NMvyMrMScnM1ZyiAaJJtzbxqN5hZOMClUTE+++
EOF
    
    # 确保配置目录存在
    mkdir -p ~/.config/bcompare
    
    # 复制密钥文件到用户配置目录
    cp /tmp/BC4Key.txt ~/.config/bcompare/BC4Key.txt
    
    # 步骤3: 为所有用户注册bcompare命令
    echo_step "步骤3: 为所有用户注册bcompare命令"
    echo_info "复制密钥文件到系统目录..."
    exec_sudo mkdir -p /etc/bcompare/
    exec_sudo cp /tmp/BC4Key.txt /etc/bcompare/
    
    # 清理临时文件
    rm -f /tmp/BC4Key.txt
    
    echo_info "Beyond Compare 4 破解完成！"
    echo_info "请按以下步骤完成激活："
    echo_info "1. 打开 Beyond Compare 4"
    echo_info "2. 在弹出的密钥输入界面，输入以下密钥："
    echo_info "   GXN1eh9FbDiX1ACdd7XKMV7hL7x0ClBJLUJ-zFfKofjaj2yxE53xauIfkqZ8FoLpcZ0Ux6McTyNmODDSvSIHLYhg1QkTxjCeSCk6ARz0ABJcnUmd3dZYJNWFyJun14rmGByRnVPL49QH+Rs0kjRGKCB-cb8IT4Gf0Ue9WMQ1A6t31MO9jmjoYUeoUmbeAQSofvuK8GN1rLRv7WXfUJ0uyvYlGLqzq1ZoJAJDyo0Kdr4ThF-IXcv2cxVyWVW1SaMq8GFosDEGThnY7C-SgNXW30jqAOgiRjKKRX9RuNeDMFqgP2cuf0NMvyMrMScnM1ZyiAaJJtzbxqN5hZOMClUTE+++"
    echo_info "3. 如果程序正在运行，请重启程序以使更改生效。"
}

# 帮助信息
show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help    显示帮助信息"
    echo ""
    echo "说明:"
    echo "  此脚本用于移除 Beyond Compare 4 的试用限制"
    echo "  脚本将按照以下步骤执行："
    echo "    1. 修改 /usr/lib/beyondcompare/ 目录下的 BCompare 文件"
    echo "    2. 创建密钥文件 ~/.config/bcompare/BC4Key.txt"
    echo "    3. 复制密钥文件到系统目录 /etc/bcompare/"
    echo ""
    echo "注意:"
    echo "  1. 此脚本可能需要 sudo 权限"
    echo "  2. 请确保已安装 Beyond Compare 4"
    echo "  3. 脚本会自动备份原始文件"
    echo "  4. 完成后需要在软件界面输入密钥"
}

# 参数处理
case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo_error "未知参数: $1"
        echo "使用 $0 --help 查看帮助信息"
        exit 1
        ;;
esac