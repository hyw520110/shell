#!/bin/bash
#当前版本仅支持CentOS7的系统


if [ `whoami` != 'root' ]; then
    echo -e "\e[1;31m 请使用root执行... \e[1;31m"
    exit 1
fi

SYSTEM_VERSION=`lsb_release  -i|awk '{print $NF}'`
KERNEL_VERSION=`uname -r|awk -F'.' '{print $1}'`
RELEASE_VERSION=`lsb_release -r|awk -F"[ \t]+"+ '{print $2}'`
#终端超时时间
TMOUT=600
#密码最小长度
PASS_MIN_LEN=8
#密码最大有效期
PASS_MAX_DAYS=90
#修改密码的最小间隔时间
PASS_MIN_DAYS=2


centos7_system_security_strengthening(){
    #datetime=`date +%Y%m%d%H%M`
    cp /etc/profile{,.security_default.bak}
    cp /etc/login.defs{,.security_default.bak}
    cp /etc/pam.d/system-auth{,.security_default.bak}
    cp /etc/pam.d/sshd{,.security_default.bak}
    cp /etc/pam.d/login{,.security_default.bak}
    cp /etc/ssh/sshd_config{,.security_default.bak}
    cp /etc/pam.d/password-auth{,.security_default.bak}
    cp /etc/pam.d/system-auth{,.security_default.bak}
    
    sed -i "/`grep 'HISTSIZE='  /etc/profile`/a TMOUT=${TMOUT}"  /etc/profile
    sed -ri "s#^(PASS_MAX_DAYS)([\t ]+)([0-9]+)#\1\2${PASS_MAX_DAYS}#g" /etc/login.defs
    sed -ri "s#^(PASS_MIN_LEN)([\t ]+)([0-9]+)#\1\2${PASS_MIN_LEN}#g" /etc/login.defs
    sed -ri "s#^(PASS_MIN_DAYS)([\t ]+)([0-9]+)#\1\2${PASS_MIN_DAYS}#g" /etc/login.defs
    
    #启用登录失败处理功能
    echo "password requisite pam_cracklib.so retry=3 difok=2 minlen=8 lcredit=-1 dcredit=-1" >> /etc/pam.d/system-auth
    echo "auth required pam_tally2.so  onerr=fail  deny=3  unlock_time=60 even_deny_root root_unlock_time=60" >> /etc/pam.d/system-auth
    echo "auth required pam_tally2.so deny=3 unlock_time=60 even_deny_root root_unlock_time=60" >> /etc/pam.d/sshd
    echo "auth required pam_tally2.so deny=3 unlock_time=60 even_deny_root root_unlock_time=60" >> /etc/pam.d/login
    
    
    #sshd
    sed -ri  "s:^(#LogLevel)([ ]+)(.*):LogLevel\2 INFO:g"  /etc/ssh/sshd_config 
    sed -ri  "s:^(#)(ClientAliveInterval)([ ]+)([0-9]+):\2\3900:g"  /etc/ssh/sshd_config 
    sed -ri  "s:^(#)(ClientAliveCountMax)([ ]+)([0-9]+):\2\30:g"  /etc/ssh/sshd_config 
    sed -ri  "s:^(#)(PermitEmptyPasswords)([ ]+)([a-z]+):\2\3\4:g"  /etc/ssh/sshd_config 
    sed -ri  "s:^(#)(MaxAuthTries)([ ]+)([0-9]+):\2\34:g"  /etc/ssh/sshd_config
    if [ `grep -i  Protocol /etc/ssh/sshd_config|wc -l` -eq 0 ]; then
        sed -i "20a Protocol 2" /etc/ssh/sshd_config
    else
        sed  -ri "s#^(Protocol)([ ]+)([0-9])#\1\22#g" /etc/ssh/sshd_config
    fi
    
    #重启sshd
    systemctl  restart sshd
    
    
    #文件权限修改
    chown root:root /etc/passwd /etc/shadow /etc/group /etc/gshadow
    chmod 644 /etc/group 
    chmod 644 /etc/passwd 
    chmod 400 /etc/shadow 
    chmod 400 /etc/gshadow
    
    
    #开启地址空间布局随机化
    sysctl -w kernel.randomize_va_space=2
    
    #强制用户不重用最近5个使用的密码，降低密码猜测攻击风险
    sed -ri "s#^(password    sufficient)(.*)#\1\2 remember=5#g" /etc/pam.d/password-auth
    sed -ri "s#^(password    sufficient)(.*)#\1\2 remember=5#g"  /etc/pam.d/system-auth
    
    #检查密码长度和密码是否使用多种字符类型
    sed -ri "s:^(# )(minlen = )([0-9]):\210:g"  /etc/security/pwquality.conf
    sed -ri "s:^(# )(minclass = )([0-9]):\23:g"  /etc/security/pwquality.conf
    
    #内核优化

}

centos_reset(){
    cp -f /etc/profile.security_default.bak             /etc/profile   
    cp -f /etc/login.defs.security_default.bak          /etc/login.defs
    cp -f /etc/pam.d/system-auth.security_default.bak   /etc/pam.d/system-auth
    cp -f /etc/pam.d/sshd.security_default.bak          /etc/pam.d/sshd
    cp -f /etc/pam.d/login.security_default.bak         /etc/pam.d/login
    cp -f /etc/ssh/sshd_config.security_default.bak     /etc/ssh/sshd_config
    cp -f /etc/pam.d/password-auth.security_default.bak /etc/pam.d/password-auth
    cp -f /etc/pam.d/system-auth.security_default.bak   /etc/pam.d/system-auth
    rm -f /etc/profile.security_default.bak            
    rm -f /etc/login.defs.security_default.bak         
    rm -f /etc/pam.d/system-auth.security_default.bak  
    rm -f /etc/pam.d/sshd.security_default.bak         
    rm -f /etc/pam.d/login.security_default.bak        
    rm -f /etc/ssh/sshd_config.security_default.bak    
    rm -f /etc/pam.d/password-auth.security_default.bak
    rm -f /etc/pam.d/system-auth.security_default.bak 
    systemctl restart sshd 
}

is_system_version(){
    case $SYSTEM_VERSION in
        CentOS)
        if [ `echo $RELEASE_VERSION 7 8|xargs  -n 1|sort  -V|awk NR==2` == $RELEASE_VERSION ]; then
            centos7_system_security_strengthening
        else
            echo -e "\e[1;31m 当前脚本仅支支持CentOS7系统... \e[1;31m"
            exit 3
        fi
        ;;
        *)
        echo -e "\e[1;31m 当前系统部署CentOS系统 \e[1;31m"
        exit 4
        ;;
    esac

}


case $1 in
    reset)
    if [ -f /etc/profile.security_default.bak -a -f /etc/login.defs.security_default.bak -a -f /etc/pam.d/system-auth.security_default.bak -a -f  /etc/pam.d/login.security_default.bak -a -f /etc/ssh/sshd_config.security_default.bak -a -f /etc/pam.d/password-auth.security_default.bak -a -f /etc/pam.d/system-auth.security_default.bak ]; then
        centos_reset
    else
        echo -e "\e[1;31m 安全优化备份文件不存在... \e[1;31m"
        exit 2
    fi
    ;;
    '')
    is_system_version
    ;;
    *)
    echo -e "\e[1;31m 仅允许传输reset与空内容 \e[1;31m"
    exit 5
    ;;

esac
