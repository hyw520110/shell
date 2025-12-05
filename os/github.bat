@echo off
setlocal enabledelayedexpansion

:: 全局变量
set "HOSTS_URL=https://gitee.com/if-the-wind/github-hosts/raw/main/hosts"
set "MARKER_START=START GITHUB HOSTS"
set "MARKER_END=END GITHUB HOSTS"
set "TEMP_FILE=%TEMP%\github_hosts.tmp"
set "BACKUP_FILE=%SystemRoot%\System32\drivers\etc\hosts.bak"

:: 日志函数
:log
echo [%date% %time%] [%~1] %~2
exit /b

:: 检查管理员权限
:check_admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    call :log ERROR "需要管理员权限来修改 hosts 文件"
    exit /b 1
)
exit /b 0

:: 获取hosts文件内容
:fetch_hosts
curl -s -f --connect-timeout 10 "%HOSTS_URL%" > "%TEMP_FILE%"
if %errorLevel% neq 0 (
    call :log ERROR "无法获取 hosts 文件内容，请检查网络或 URL: %HOSTS_URL%"
    exit /b 1
)
:: 过滤注释行
findstr /v "^#" "%TEMP_FILE%" > "%TEMP_FILE%.tmp"
move /y "%TEMP_FILE%.tmp" "%TEMP_FILE%" >nul
exit /b 0

:: 更新hosts文件
:update_hosts
call :log INFO "开始更新 hosts 文件..."

call :fetch_hosts
if %errorLevel% neq 0 exit /b 1

:: 备份原始hosts文件
copy /y "%SystemRoot%\System32\drivers\etc\hosts" "%BACKUP_FILE%" >nul
if %errorLevel% neq 0 (
    call :log ERROR "无法备份原始 hosts 文件"
    exit /b 1
)

:: 处理现有hosts文件，移除旧的GitHub hosts部分
findstr /v "%MARKER_START%" "%SystemRoot%\System32\drivers\etc\hosts" | findstr /v "%MARKER_END%" > "%TEMP_FILE%.new"
if %errorLevel% neq 0 (
    call :log ERROR "处理 hosts 文件失败"
    exit /b 1
)

:: 添加新的hosts内容
echo. >> "%TEMP_FILE%.new"
echo # %MARKER_START% >> "%TEMP_FILE%.new"
type "%TEMP_FILE%" >> "%TEMP_FILE%.new"
echo # %MARKER_END% >> "%TEMP_FILE%.new"

:: 更新hosts文件
move /y "%TEMP_FILE%.new" "%SystemRoot%\System32\drivers\etc\hosts" >nul
if %errorLevel% neq 0 (
    call :log ERROR "更新 hosts 文件失败"
    exit /b 1
)

call :log INFO "hosts 文件更新成功"
exit /b 0

:: 清理临时文件
:cleanup
if exist "%TEMP_FILE%" del /f "%TEMP_FILE%"
if exist "%TEMP_FILE%.new" del /f "%TEMP_FILE%.new"
exit /b 0

:: 主函数
:main
call :check_admin
if %errorLevel% neq 0 exit /b 1

call :update_hosts
if %errorLevel% neq 0 exit /b 1

call :cleanup
call :log INFO "脚本执行完成"
exit /b 0

:: 启动主函数
call :main