@echo off

:: 定义通用部署函数
:deployArtifact
setlocal
set "file=%~1"
set "groupId=%~2"
set "artifactId=%~3"
set "version=%~4"
set "packaging=%~5"
set "repositoryId=%~6"
set "url=%~7"

:: 检查文件是否存在
if not exist "%file%" (
    echo 错误: 文件不存在: %file%
    exit /b 1
)

echo 正在部署: %file%
call mvn deploy:deploy-file -Dfile="%file%" -DgroupId="%groupId%" -DartifactId="%artifactId%" -Dversion="%version%" -Dpackaging="%packaging%" -DrepositoryId="%repositoryId%" -Durl="%url%" -e
if %errorlevel% neq 0 (
    echo 部署失败: %file%
    exit /b 1
)
echo 部署成功: %file%
endlocal
goto :eof

:: 配置仓库URL
set "repoUrl=http://maven.shangjinuu.com:8081/nexus/content/repositories"

:: 定义待部署的文件及配置
set "deployments=^
D:\uubee-sms-0.0.1-SNAPSHOT.pom,com.uubee,uubee-sms,0.0.1-SNAPSHOT,pom,snapshots,%repoUrl%/snapshots/;^
D:\uubee-sms-0.0.1-SNAPSHOT.jar,com.uubee,uubee-sms,0.0.1-SNAPSHOT,jar,snapshots,%repoUrl%/snapshots/;^
D:\tmp\validator-1.3.2.pom,com.faj.bean,validator,1.3.2,pom,releases,%repoUrl%/thirdparty/;^
D:\tmp\validator-1.3.2.jar,com.faj.bean,validator,1.3.2,jar,releases,%repoUrl%/thirdparty/;^
D:\tmp\little-utils-1.5.16.pom,com.little,little-utils,1.5.16,pom,releases,%repoUrl%/thirdparty/;^
D:\tmp\little-utils-1.5.16.jar,com.little,little-utils,1.5.16,jar,releases,%repoUrl%/thirdparty/;^
D:\tmp\top-api-sdk-java-1.0.pom,com.taobao.top,top-api-sdk-java,1.0,pom,releases,%repoUrl%/thirdparty/;^
D:\tmp\top-api-sdk-java-1.0.jar,com.taobao.top,top-api-sdk-java,1.0,jar,releases,%repoUrl%/thirdparty/;^
D:\tmp\lippi-oapi-encrpt-dingtalk-1.0.pom,com.taobao.top,lippi-oapi-encrpt-dingtalk,1.0,pom,releases,%repoUrl%/thirdparty/;^
D:\tmp\lippi-oapi-encrpt-dingtalk-1.0.jar,com.taobao.top,lippi-oapi-encrpt-dingtalk,1.0,jar,releases,%repoUrl%/thirdparty/;^
D:\tmp\atom-1.0-SNAPSHOT.pom,com.atom,atom,1.0-SNAPSHOT,pom,snapshots,%repoUrl%/snapshots/;^
D:\tmp\value-extract-1.0-SNAPSHOT.jar,com.faj,value-extract,1.0-SNAPSHOT,jar,snapshots,%repoUrl%/snapshots/;^
D:\tmp\pay_lock_interface-0.0.1-SNAPSHOT.jar,com.uubee,pay_lock_interface,0.0.1-SNAPSHOT,jar,snapshots,%repoUrl%/snapshots/;^
D:\tmp\uubee-sms-interface-0.0.1-SNAPSHOT.jar,com.uubee,uubee-sms-interface,0.0.1-SNAPSHOT,jar,snapshots,%repoUrl%/snapshots/;^
D:\tmp\transmittable-thread-local-2.11.4.jar,com.alibaba,transmittable-thread-local,2.11.4,jar,releases,%repoUrl%/releases/"

:: 遍历部署
for %%d in (%deployments%) do (
    for /f "tokens=1-7 delims=," %%a in ("%%d") do (
        call :deployArtifact "%%a" "%%b" "%%c" "%%d" "%%e" "%%f" "%%g"
    )
)

pause
