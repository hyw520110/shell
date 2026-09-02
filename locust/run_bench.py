#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Locust 压测智能启动器 - 跨平台支持
自动检测运行环境，优先使用 Docker，其次 WSL2，最后直接执行
"""

import os
import sys
import subprocess
import platform
import shutil
from pathlib import Path

# 脚本所在目录
SCRIPT_DIR = Path(__file__).parent.absolute()
REPORT_DIR = Path.home() / "locust_reports"

# 依赖配置
REQUIRED_PYTHON_PACKAGES = ["locust", "pandas", "beautifulsoup4", "lxml", "requests", "jinja2"]
REQUIRED_SYSTEM_PACKAGES = ["python3", "pip3", "bc"]


def print_info(msg):
    print(f"\033[0;32m[信息]\033[0m {msg}")


def print_warn(msg):
    print(f"\033[0;33m[警告]\033[0m {msg}")


def print_error(msg):
    print(f"\033[0;31m[错误]\033[0m {msg}")


def run_command(cmd, capture=False, check=True):
    """执行命令"""
    try:
        if capture:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=check)
            return result.returncode == 0, result.stdout.strip()
        else:
            result = subprocess.run(cmd, shell=True, check=check)
            return result.returncode == 0, ""
    except subprocess.CalledProcessError as e:
        return False, str(e)
    except Exception as e:
        return False, str(e)


def check_docker():
    """检查 Docker 是否已安装并运行"""
    print_info("检查 Docker 环境...")
    
    # 检查 Docker 命令
    success, _ = run_command("docker --version", capture=True, check=False)
    if not success:
        print_warn("Docker 未安装")
        return False
    
    # 检查 Docker 是否运行
    success, _ = run_command("docker info", capture=True, check=False)
    if not success:
        print_warn("Docker 未运行")
        return False
    
    print_info("✅ Docker 已就绪")
    return True


def check_wsl():
    """检查 WSL2 是否可用"""
    print_info("检查 WSL2 环境...")
    
    # 检查 wsl 命令
    success, _ = run_command("wsl --version", capture=True, check=False)
    if not success:
        print_warn("WSL 未安装")
        return False
    
    # 检查 WSL 发行版
    success, output = run_command("wsl --list --running", capture=True, check=False)
    if not success or not output:
        print_warn("没有运行中的 WSL 发行版")
        return False
    
    print_info("✅ WSL2 已就绪")
    return True


def check_python_packages():
    """检查 Python 依赖"""
    missing = []
    for pkg in REQUIRED_PYTHON_PACKAGES:
        success, _ = run_command(f"python3 -c \"import {pkg}\"", capture=False, check=False)
        if not success:
            missing.append(pkg)
    
    return missing


def check_system_packages_wsl():
    """检查 WSL 系统依赖"""
    missing = []
    for pkg in REQUIRED_SYSTEM_PACKAGES:
        success, _ = run_command("wsl which " + pkg, capture=True, check=False)
        if not success:
            missing.append(pkg)
    
    return missing


def install_python_packages():
    """安装 Python 依赖"""
    print_info("正在安装 Python 依赖...")
    success, _ = run_command(f"{sys.executable} -m pip install -q -r {SCRIPT_DIR}/requirements.txt")
    if success:
        print_info("✅ Python 依赖安装完成")
    else:
        print_error("Python 依赖安装失败")
    return success


def install_system_packages_wsl():
    """在 WSL 中安装系统依赖"""
    print_info("正在 WSL 中安装系统依赖...")
    
    # 更新包列表并安装
    cmd = "wsl bash -c \"sudo apt-get update && sudo apt-get install -y bc python3 python3-pip\""
    success, _ = run_command(cmd)
    
    if success:
        print_info("✅ WSL 系统依赖安装完成")
    else:
        print_error("WSL 系统依赖安装失败")
    
    return success


def run_docker(args):
    """使用 Docker 运行"""
    print_info("使用 Docker 运行压测...")
    
    # 确保报告目录存在
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    
    # 构建 Docker 命令
    docker_args = " ".join(args)
    cmd = (
        f"docker run --rm -it "
        f"-v \"{REPORT_DIR}\":/root/locust_reports "
        f"-v \"{SCRIPT_DIR}\":/locust "
        f"-w /locust "
        f"locust-bench {docker_args}"
    )
    
    print_info(f"执行：{cmd}")
    success, _ = run_command(cmd, check=False)
    return success


def run_wsl(args):
    """使用 WSL 运行"""
    print_info("使用 WSL 运行压测...")
    
    # 确保报告目录存在
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    
    # 构建 WSL 命令
    script_path = SCRIPT_DIR / "distributedbench.sh"
    wsl_args = " ".join(args)
    
    # 将 Windows 路径转换为 WSL 路径
    wsl_script = str(script_path).replace("\\", "/").replace("C:", "/mnt/c")
    wsl_report_dir = str(REPORT_DIR).replace("\\", "/").replace("C:", "/mnt/c")
    
    cmd = f'wsl bash -c "BASE_REPORT_DIR={wsl_report_dir} {wsl_script} {wsl_args}"'
    
    print_info(f"执行：{cmd}")
    success, _ = run_command(cmd, check=False)
    return success


def run_native(args):
    """本地运行（Linux/macOS）"""
    print_info("本地运行压测...")
    
    # 确保报告目录存在
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    
    script_path = SCRIPT_DIR / "distributedbench.sh"
    
    # 设置环境变量
    env = os.environ.copy()
    env["BASE_REPORT_DIR"] = str(REPORT_DIR)
    
    cmd = ["bash", str(script_path)] + args
    
    try:
        subprocess.run(cmd, env=env, check=False)
        return True
    except Exception as e:
        print_error(f"执行失败：{e}")
        return False


def main():
    """主函数"""
    # 解析参数（跳过脚本名）
    args = sys.argv[1:]
    
    if not args or "-h" in args or "--help" in args:
        print("""
Locust 压测智能启动器

用法：python run_bench.py [选项]

选项:
  -H <URL>       目标主机地址
  -u <数字>      起始并发用户数
  -t <秒>        单轮测试时长
  -r <数字>      用户增长速率/秒
  -m <倍数>      递进倍率（设置此项即开启阶梯模式）
  -c <数字>      硬性并发上限
  -d             分布式模式
  -q             简洁模式（带进度条）
  -x             破坏性测试模式

示例:
  python run_bench.py -H http://target.com -u 100 -t 60
  python run_bench.py -H http://target.com -u 100 -m 1.5 -q
""")
        return 0
    
    print("=" * 60)
    print("Locust 压测智能启动器")
    print("=" * 60)
    
    # 1. 优先尝试 Docker
    if check_docker():
        # 检查镜像是否存在
        success, _ = run_command("docker images -q locust-bench", capture=True, check=False)
        if not success:
            print_warn("Docker 镜像不存在，正在构建...")
            
            dockerfile = SCRIPT_DIR / "Dockerfile"
            if dockerfile.exists():
                cmd = f"docker build -t locust-bench \"{SCRIPT_DIR}\""
                success, _ = run_command(cmd)
                if not success:
                    print_error("Docker 镜像构建失败")
                    return 1
                print_info("✅ Docker 镜像构建完成")
            else:
                print_error("Dockerfile 不存在")
                return 1
        
        return 0 if run_docker(args) else 1
    
    # 2. 其次尝试 WSL2
    if check_wsl():
        # 检查 WSL 依赖
        missing = check_system_packages_wsl()
        if missing:
            print_warn(f"WSL 缺少依赖：{', '.join(missing)}")
            response = input("是否自动安装？(y/n): ")
            if response.lower() == 'y':
                if not install_system_packages_wsl():
                    return 1
            else:
                print_error("依赖未安装，无法继续")
                return 1
        
        # 检查 Python 依赖
        missing = check_python_packages()
        if missing:
            print_warn(f"WSL 中 Python 缺少依赖：{', '.join(missing)}")
            response = input("是否自动安装？(y/n): ")
            if response.lower() == 'y':
                cmd = "wsl bash -c \"pip3 install -q -r requirements.txt\""
                success, _ = run_command(cmd)
                if not success:
                    print_error("Python 依赖安装失败")
                    return 1
                print_info("✅ Python 依赖安装完成")
            else:
                print_error("依赖未安装，无法继续")
                return 1
        
        return 0 if run_wsl(args) else 1
    
    # 3. 最后尝试本地运行（Linux/macOS）
    system = platform.system()
    if system in ["Linux", "Darwin"]:
        print_info("使用本地环境运行...")
        
        # 检查系统依赖
        for pkg in ["bc", "python3"]:
            if not shutil.which(pkg):
                print_error(f"缺少系统依赖：{pkg}")
                return 1
        
        # 检查 Python 依赖
        missing = check_python_packages()
        if missing:
            print_warn(f"Python 缺少依赖：{', '.join(missing)}")
            response = input("是否自动安装？(y/n): ")
            if response.lower() == 'y':
                if not install_python_packages():
                    return 1
            else:
                print_error("依赖未安装，无法继续")
                return 1
        
        return 0 if run_native(args) else 1
    
    # 4. 不支持的平台
    print_error(f"不支持的操作系统：{system}")
    print_info("建议安装 WSL2 或 Docker Desktop")
    return 1


if __name__ == "__main__":
    sys.exit(main())
