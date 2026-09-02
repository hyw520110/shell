@echo off
chcp 65001 >nul
title Locust 分布式压测启动器

:: ==============================================
:: Locust 压测启动器 - 支持 WSL2/Docker
:: 用法：双击运行 或 命令行传递参数
:: ==============================================

setlocal enabledelayedexpansion

:: 获取脚本所在目录
set SCRIPT_DIR=%~dp0

:: 检查参数
if "%~1"=="" goto :show_help
if "%~1"=="--setup" goto :setup_wsl
if "%~1"=="--shortcut" goto :create_shortcut
if "%~1"=="-h" goto :show_help
if "%~1"=="--help" goto :show_help

:: 检查 WSL 是否安装
wsl --version >nul 2>&1
if %errorlevel% neq 0 (
    echo ==============================================
    echo [错误] WSL 未安装！
    echo ==============================================
    echo.
    echo 请先安装 WSL2 (管理员 PowerShell):
    echo   wsl --install -d Ubuntu
    echo.
    echo 或使用以下命令自动设置环境:
    echo   run.bat --setup
    echo.
    pause
    exit /b 1
)

:: 检查 Docker 是否运行（优先使用）
docker info >nul 2>&1
if %errorlevel% equ 0 (
    echo [信息] 检测到 Docker 已运行，使用 Docker 模式...
    echo.
    goto :run_docker
)

:: 使用 WSL2 运行
echo [信息] 使用 WSL2 运行压测...
echo.
goto :run_wsl

:setup_wsl
echo ==============================================
echo Locust 压测 - WSL2 环境设置
echo ==============================================
echo.
echo [信息] 正在 WSL 中执行环境设置...
echo.

wsl bash -c "cd %SCRIPT_DIR:~0,-1% && bash setup_wsl.sh"

if %errorlevel% neq 0 (
    echo.
    echo ==============================================
    echo [错误] WSL 设置失败！
    echo ==============================================
    echo.
    pause
    exit /b 1
)

echo.
echo ==============================================
echo 设置完成！
echo ==============================================
echo.
echo 运行压测:
echo   run.bat -H http://target.com -u 100
echo.
pause
exit /b 0

:create_shortcut
echo ==============================================
echo 创建桌面快捷方式
echo ==============================================
echo.

set SHORTCUT_PATH=%USERPROFILE%\Desktop\Locust 压测.lnk

powershell -Command "$WshShell = New-Object -ComObject WScript.Shell; $Shortcut = $WshShell.CreateShortcut('%SHORTCUT_PATH%'); $Shortcut.TargetPath = '%SCRIPT_DIR:~0,-1%run.bat'; $Shortcut.WorkingDirectory = '%SCRIPT_DIR:~0,-1%'; $Shortcut.IconLocation = 'shell32.dll,15'; $Shortcut.Description = 'Locust 分布式压测启动器'; $Shortcut.Save()"

if %errorlevel% equ 0 (
    echo ✅ 快捷方式已创建到桌面！
    echo.
    echo 双击桌面上的 "Locust 压测" 快捷方式即可运行
    echo.
) else (
    echo [错误] 创建失败，请手动运行 run.bat
    echo.
)

pause
exit /b 0

:run_docker
REM 检查镜像是否存在
docker images -q locust-bench >nul 2>&1
if %errorlevel% neq 0 (
    echo [信息] Docker 镜像不存在，正在构建...
    docker build -t locust-bench "%SCRIPT_DIR:~0,-1%"
    if %errorlevel% neq 0 (
        echo [错误] Docker 镜像构建失败
        pause
        exit /b 1
    )
)

REM 创建报告目录
if not exist "%USERPROFILE%\locust_reports" mkdir "%USERPROFILE%\locust_reports"

REM 运行 Docker
docker run --rm -it ^
  -v "%USERPROFILE%\locust_reports:/root/locust_reports" ^
  -v "%SCRIPT_DIR:~0,-1%:/locust" ^
  -w /locust ^
  locust-bench %*

goto :end

:run_wsl
REM 创建报告目录
if not exist "%USERPROFILE%\locust_reports" mkdir "%USERPROFILE%\locust_reports"

REM 在 WSL 中运行
wsl bash -c "cd %SCRIPT_DIR:~0,-1% && BASE_REPORT_DIR=/mnt/c/Users/%USERNAME%/locust_reports ./distributedbench.sh %*"

goto :end

:show_help
echo ==============================================
echo Locust 分布式压测启动器
echo ==============================================
echo.
echo 用法:
echo   双击运行：run.bat -H http://target.com -u 100
echo   命令行：   run.bat -H http://target.com -u 100
echo.
echo 选项:
echo   -H ^<URL^>     目标主机地址（必需）
echo   -u ^<数字^>    起始并发用户数
echo   -t ^<秒^>      单轮测试时长
echo   -r ^<数字^>    用户增长速率/秒
echo   -m ^<倍数^>    递进倍率（阶梯模式）
echo   -c ^<数字^>    硬性并发上限
echo   -d           分布式模式
echo   -q           简洁模式（带进度条）
echo   -x           破坏性测试模式
echo.
echo 特殊命令:
echo   run.bat --setup      设置 WSL2 环境（首次运行）
echo   run.bat --shortcut   创建桌面快捷方式
echo.
echo 示例:
echo   run.bat -H https://www.baidu.com -u 100 -t 60
echo   run.bat -H https://www.baidu.com -u 100 -m 1.5 -q
echo   run.bat --setup
echo   run.bat --shortcut
echo.
echo 运行环境:
echo   1. Docker（优先）
echo   2. WSL2
echo.
pause
exit /b 0

:end
if %errorlevel% neq 0 (
    echo.
    echo ==============================================
    echo [错误] 压测执行失败，错误码：%errorlevel%
    echo ==============================================
    echo.
    pause
)
