@echo off

rem call mvn deploy:deploy-file -Dfile=D:\uubee-sms-0.0.1-SNAPSHOT.pom -DgroupId=com.uubee -DartifactId=uubee-sms -Dversion=0.0.1-SNAPSHOT -Dpackaging=pom -DrepositoryId=snapshots -Durl=http://10.1.100.100:8081/nexus/content/repositories/snapshots/  -e

rem call mvn deploy:deploy-file -Dfile=D:\tmp\validator-1.3.2.pom -DgroupId=com.faj.bean -DartifactId=validator -Dversion=1.3.2 -Dpackaging=pom -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/thirdparty/  -e
rem call mvn deploy:deploy-file -Dfile=D:\tmp\validator-1.3.2.jar -DgroupId=com.faj.bean -DartifactId=validator -Dversion=1.3.2 -Dpackaging=jar -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/thirdparty/  -e

rem call mvn deploy:deploy-file -Dfile=D:\tmp\little-utils-1.5.16.pom -DgroupId=com.little -DartifactId=little-utils -Dversion=1.5.16 -Dpackaging=pom -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/thirdparty/  -e
rem call mvn deploy:deploy-file -Dfile=D:\tmp\little-utils-1.5.16.jar -DgroupId=com.little -DartifactId=little-utils -Dversion=1.5.16 -Dpackaging=jar -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/thirdparty/  -e

rem call mvn deploy:deploy-file -Dfile=D:\tmp\top-api-sdk-java-1.0.pom -DgroupId=com.taobao.top -DartifactId=top-api-sdk-java -Dversion=1.0 -Dpackaging=pom -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/thirdparty/  -e
rem call mvn deploy:deploy-file -Dfile=D:\tmp\top-api-sdk-java-1.0.jar -DgroupId=com.taobao.top -DartifactId=top-api-sdk-java -Dversion=1.0 -Dpackaging=jar -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/thirdparty/  -e

rem call mvn deploy:deploy-file -Dfile=D:\tmp\lippi-oapi-encrpt-dingtalk-1.0.pom -DgroupId=com.taobao.top -DartifactId=lippi-oapi-encrpt-dingtalk -Dversion=1.0 -Dpackaging=pom -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/thirdparty/  -e
rem call mvn deploy:deploy-file -Dfile=D:\tmp\lippi-oapi-encrpt-dingtalk-1.0.jar -DgroupId=com.taobao.top -DartifactId=lippi-oapi-encrpt-dingtalk -Dversion=1.0 -Dpackaging=jar -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/thirdparty/  -e

rem call mvn deploy:deploy-file -Dfile=D:\tmp\sso-client-1.1.pom -DgroupId=com.lianxin -DartifactId=sso-client -Dversion=1.1 -Dpackaging=pom -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/releases/  -e
rem call mvn deploy:deploy-file -Dfile=D:\tmp\sso-client-1.1.jar -DgroupId=com.lianxin -DartifactId=sso-client -Dversion=1.1 -Dpackaging=jar -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/releases/  -e

rem call mvn deploy:deploy-file -Dfile=D:\tmp\atom-1.0-SNAPSHOT.pom -DgroupId=com.atom -DartifactId=atom -Dversion=1.0-SNAPSHOT -Dpackaging=pom -DrepositoryId=snapshots -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/snapshots/  -e
rem call mvn deploy:deploy-file -Dfile=d:\tmp\lianxin-rectag-interface-1.0-SNAPSHOT.jar -DgroupId=com.lianxin -DartifactId=lianxin-rectag-interface -Dversion=1.0-SNAPSHOT -Dpackaging=jar -DrepositoryId=snapshots -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/snapshots/
rem call mvn deploy:deploy-file -Dfile=d:\tmp\oss-1.2-SNAPSHOT.jar -DgroupId=com.lianxin -DartifactId=oss -Dversion=1.2-SNAPSHOT -Dpackaging=jar -DrepositoryId=snapshots -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/snapshots/
rem call mvn deploy:deploy-file -Dfile=d:\tmp\value-extract-1.0-SNAPSHOT.jar -DgroupId=com.faj -DartifactId=value-extract -Dversion=1.0-SNAPSHOT -Dpackaging=jar -DrepositoryId=snapshots -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/snapshots/
rem call mvn deploy:deploy-file -Dfile=d:\tmp\pay_lock_interface-0.0.1-SNAPSHOT.jar -DgroupId=com.uubee -DartifactId=pay_lock_interface -Dversion=0.0.1-SNAPSHOT -Dpackaging=jar -DrepositoryId=snapshots -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/snapshots/
rem call mvn deploy:deploy-file -Dfile=d:\tmp\uubee-sms-interface-0.0.1-SNAPSHOT.jar -DgroupId=com.uubee -DartifactId=uubee-sms-interface -Dversion=0.0.1-SNAPSHOT -Dpackaging=jar -DrepositoryId=snapshots -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/snapshots/
rem call mvn deploy:deploy-file -Dfile=d:\tmp\transmittable-thread-local-2.11.4.jar -DgroupId=com.alibaba -DartifactId=transmittable-thread-local -Dversion=2.11.4 -Dpackaging=jar -DrepositoryId=releases -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/releases/
call mvn deploy:deploy-file -Dfile=d:\tmp\lianxin-bigdatalabel-interface-1.0-SNAPSHOT.jar -DgroupId=com.lianxin -DartifactId=lianxin-bigdatalabel-interface -Dversion=1.0-SNAPSHOT -Dpackaging=jar -DrepositoryId=snapshots -Durl=http://maven.shangjinuu.com:8081/nexus/content/repositories/snapshots/


pause
