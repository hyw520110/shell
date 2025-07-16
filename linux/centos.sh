#!/usr/bin/env bash
LOG_FILE="/var/log/init_server.log"
if [[ "$(whoami)" != "root" ]]; then
    echo "Please run this script as root." >&2 && exit 1
fi
SERVICE=$(which service)
CHKCONFIG=$(which chkconfig)
. /etc/rc.d/init.d/functions
init_hostname() {
    while true; do
        read -p "请输入您想设定的主机名：" name
        if [ -z "$name" ]; then
            echo -e "\033[31m 您没有输入内容，请重新输入 \033[0m"
            continue
        fi
        read -p "您确认使用该主机名吗？[y/n]: " var
        if [[ $var == 'y' || $var == 'yes' ]]; then
            hostnamectl set-hostname "$name"
            break
        fi
    done
}

init_security() {
    systemctl stop firewalld
    systemctl disable firewalld >> "$LOG_FILE" 2>&1
    setenforce 0
    sed -i '/^SELINUX=/ s/enforcing/disabled/' /etc/selinux/config
    sed -i '/^GSSAPIAu/ s/yes/no/' /etc/ssh/sshd_config
    sed -i '/^#UseDNS/ {s/^#//;s/yes/no/}' /etc/ssh/sshd_config
    systemctl enable sshd crond >> "$LOG_FILE" 2>&1
    echo -e "\033[32m [安全配置] ==> OK \033[0m"
}

init_yumsource() {
    local backup_dir="/etc/yum.repos.d/backup"
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
    fi
    mv /etc/yum.repos.d/* "$backup_dir" 2>> "$LOG_FILE"
    if ! ping -c 1 baidu.com >> "$LOG_FILE" 2>&1; then
        echo "您无法上外网，不能配置yum源" | tee -a "$LOG_FILE"
        exit 1
    fi
    curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo >> "$LOG_FILE" 2>&1
    yum -y install epel-release >> "$LOG_FILE" 2>&1
    yum clean all >> "$LOG_FILE" 2>&1
    yum makecache >> "$LOG_FILE" 2>&1
    sleep 1
    echo -e "\033[32m [YUM Source] ==> OK \033[0m"
}

install_tool() {
    echo "#--Install sysstat lrzsz rsync bash-completion iptables--"
    yum -y install sysstat lrzsz utpdate rsync wget bash-completion iptables-services vim-enhanced net-tools lsof wget lrzsz tree >> "$LOG_FILE" 2>&1
    [ $? -eq 0 ] && action $"Install Init Packages:" /bin/true || action $"Install Init Packages:" /bin/false
    sleep 1
}

install_comm_tool() {
    echo "#--Install common Packages--"
    yum install -y gcc cmake bzip2-devel curl-devel db4-devel libjpeg-devel libpng-devel freetype-devel libXpm-devel gmp-devel libc-client-devel openldap-devel unixODBC-devel postgresql-devel sqlite-devel aspell-devel net-snmp-devel libxslt-devel libxml2-devel pcre-devel mysql-devel pspell-devel libmemcached libmemcached-devel zlib-devel >> "$LOG_FILE" 2>&1
    [ $? -eq 0 ] && action $"Install common Packages:" /bin/true || action $"Install common Packages:" /bin/false
    sleep 1
}

install_man_chinese() {
    echo "#--Install man chinese Packages--"
    yum install man-pages-zh-CN.noarch -y >> "$LOG_FILE" 2>&1
    [ $? -eq 0 ] && action $"Install man chinese Packages:" /bin/true || action $"Install man chinese Packages:" /bin/false
    sleep 1
}

init_cn_utf8() {
    echo "#--set LANG="zh_CN.UTF-8"--"
    cp /etc/locale.conf /etc/locale.conf.$(date +%F)
    sed -i 's#LANG="en_US.UTF-8"#LANG="zh_CN.UTF-8"#' /etc/locale.conf
    source /etc/locale.conf
    [ $(grep zh_CN.UTF-8 /etc/locale.conf | wc -l) -eq 1 ] && action $"Set Charset CN_UTF8:" /bin/true || action $"Set Charset CN_UTF8:" /bin/false
    sleep 1
}

init_firewall() {
    echo "#--Close Selinux and Iptables--"
    cp /etc/selinux/config /etc/selinux/config.$(date +"%Y-%m-%d_%H:%M:%S")
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
    setenforce 0
    systemctl stop firewalld.service
    systemctl disable firewalld.service
    systemctl stop iptables.service
    systemctl status iptables.service
    grep SELINUX=disabled /etc/selinux/config
    echo "Close selinux->OK and iptables->OK"
    sleep 1
}

init_ssh() {
    echo "#--sshConfig--#"
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.$(date +%F%T)
    sed -i 's%#Port 22%Port 1020%' /etc/ssh/sshd_config
    sed -i 's%#PermitRootLogin yes%PermitRootLogin no%' /etc/ssh/sshd_config
    sed -i 's%#PermitEmptyPasswords no%PermitEmptyPasswords no%' /etc/ssh/sshd_config
    sed -i 's%#UseDNS yes%UseDNS no%' /etc/ssh/sshd_config
    egrep "UseDNS|1020|^PermitRootLogin|^PermitEmptyPasswords" /etc/ssh/sshd_config
    systemctl restart sshd && action $"--sshConfig--" /bin/true || action $"--sshConfig--" /bin/false
    sleep 1
}

add_sa_user() {
    echo "#--add sys user for all member--"
    datetmp=$(date +"%Y-%m-%d_%H-%M-%S")
    cp /etc/sudoers /etc/sudoers.${datetmp}
    saUserArr=(user1 user2)
    [ $(grep "^sa:" /etc/group | wc -l) -lt 1 ] && groupadd -g 901 sa || echo "group sa already exists"
    for ((i = 0; i < ${#saUserArr[@]}; i++)); do
        if [ $(grep "${saUserArr[$i]}" /etc/passwd | wc -l) -lt 1 ]; then
            # add sys user
            useradd -g sa -u 90${i} ${saUserArr[$i]}
            # set passwd
            echo "${saUserArr[$i]}123456!@#$%^" | passwd ${saUserArr[$i]} --stdin
            # set sudo power
        else
            echo "user ${saUserArr[$i]} already exists"
        fi
    done
    [ $(grep "\%sa" /etc/sudoers | wc -l) -ne 1 ] && echo "%sa ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers
    /usr/sbin/visudo -c
    [ $? -ne 0 ] && cp /etc/sudoers.${datetmp} /etc/sudoers && echo $"Sudoers not config"
    action $"#--add sys user for all member-->OK" /bin/true
    sleep 1
}

sync_system_time() {
    echo "#--set system time syn--"
    if [ $(grep /usr/sbin/ntpdate /var/spool/cron/root | grep -v grep | wc -l) -lt 1 ]; then
        echo "*/5 * * * * /sbin/ntpdate cn.pool.ntp.org >/dev/null 2>&1" >>/var/spool/cron/root
    fi
}

open_files() {
    echo "#--set openFiles Num 65535--"
    cp /etc/security/limits.conf /etc/security/limits.conf.$(date +%F_%T)
    if [ $(grep -P "\*\t\t-\tnofile\t\t65535" /etc/security/limits.conf | wc -l) -lt 1 ]; then
        sed -i '/# End of file/i\*\t\t-\tnofile\t\t65535' /etc/security/limits.conf
        ulimit -HSn 65535
    fi
    echo "set maxnum openfiles successful"
    sleep 1
}

optimization_kernel() {
    echo "#--Optimization kernel--"
    cp /etc/sysctl.conf /etc/sysctl.conf.$(date +%F_%T)
    if [ $(grep "net.ipv4.ip_local_port_range = 1024 65535" /etc/sysctl.conf | wc -l) -lt 1 ]; then
        cat >>/etc/sysctl.conf <<EOF
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_mem = 94500000 915000000 927000000
net.ipv4.tcp_max_orphans = 3276800
net.core.wmem_default = 8288608
net.core.rmem_default = 8388608
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 32768
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 1
net.ipv4.tcp_fin_timeout = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.ip_local_port_range = 10240 65000
EOF
    fi
    modprobe bridge
    echo "modprobe bridge" >>/etc/rc.local && sysctl -p >/dev/null 2>&1
    /sbin/sysctl -p && action $"Kernel OPT:" /bin/true || action $"Kernel OPT:" /bin/false
    sleep 1
}

vim_set() {
    echo "#--Vim set--"
    cp /root/.vimrc /root/.vimrc.$(date +%F_%T)
    cat >>/root/.vimrc <<EOF
set history=1000
autocmd InsertLeave * se cul
autocmd InsertLeave * se nocul
set nu
set bs=2
syntax on
set laststatus=2
set tabstop=4
set go=
set ruler
set showcmd
set cmdheight=1
hi CursorLine cterm=NONE ctermbg=blue ctermfg=white guibg=blue guifg=white
set hls
set cursorline
set ignorecase
set hlsearch
set incsearch
set helplang=cn

inoremap ( ()<ESC>i
inoremap [ []<ESC>i
inoremap { {}<ESC>i
inoremap < <><ESC>i
inoremap " ""<ESC>i
inoremap ‘ ‘‘<ESC>i
EOF
}

init_safe() {
    echo "#--forbid ctrl+alt+del reboot system---"
    rm -f /usr/lib/systemd/system/ctrl-alt-del.target
    /sbin/init q
    [ $? -eq 0 ] && action $"forbid ctrl+alt+del reboot system:" /bin/true || action $"forbid ctrl+alt+del reboot system" /bin/false
    sleep 1
}

init_rc_local() {
    echo "#--to /etc/rc.local execute permissions---"
    chmod +x /etc/rc.d/rc.local
    [ $? -eq 0 ] && action $"to /etc/rc.local execute permissions:" /bin/true || action $"to /etc/rc.local execute permissions:" /bin/false
    sleep 1
}

disable_ipv6() {
    echo "#--forbid use IPV6--"
    cp /etc/sysctl.conf /etc/sysctl.conf.$(date +%F_%T)
    cat >>/etc/sysctl.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    [ $? -eq 0 ] && action $"forbid use IPV6:" /bin/true || action $"forbid use IPV6:" /bin/false
    sysctl -p
    sleep 1
}

main_menu() {
    echo "A --Disable iptables, selinux, nouseful, and forbid ctrl+alt+del reboot system"
    echo "B --Set sshConfig and change port 22->1020 and forbid root login"
    echo "C --Add group SA users and edit sudoers"
    echo "D --Update system time for cron"
    echo "E --Optimize system kernel"
    echo "F --Install zabbix tools"
    echo "G --Disable IPV6"
    echo "H --Edit sysopenfile num to 65535"
    echo "I --Install Common tools"
    echo "J --Install common devel"
    echo "K --Vim set for root"
    echo "L --One key init install"
    echo "Q --Quit"
    option="-1"
    read -n1 -t20 -p "Choose one of A-B-C-D-E-F-G-H-I-J-K-L:::" option
    flag1=$(echo $option | egrep "-1" | wc -l)
    flag2=$(echo $option | egrep "[A-Za-z]" | wc -l)

    if [ $flag1 -eq 1 ]; then
        option="L"
    elif [ $flag2 -ne 1 ]; then
        echo "Pls input A--->L letter"
        exit 1
    fi

    echo -e "\nyour choose is: $option\n"
    case $option in
    A|a)
        init_firewall && init_safe && init_rc_local
        ;;
    B|b)
        init_ssh
        ;;
    C|c)
        add_sa_user
        ;;
    D|d)
        sync_system_time
        ;;
    E|e)
        optimization_kernel
        ;;
    G|g)
        disable_ipv6
        ;;
    H|h)
        open_files
        ;;
    I|i)
        install_tool
        ;;
    J|j)
        install_comm_tool
        ;;
    K|k)
        vim_set
        ;;
    L|l)
        install_tool && init_yumsource && init_firewall && init_ssh && add_sa_user && sync_system_time && open_files && optimization_kernel && init_safe && init_rc_local && disable_ipv6
        ;;
    Q|q)
        exit
        ;;
    *)
        echo "Please input A-L, thank you!" && exit 1
        ;;
    esac
}
main_menu