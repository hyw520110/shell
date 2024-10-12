###################优化项目说明###################
#ConfigYum #配置阿里云YUM源
#installTool #安装常用工具
#installCommTool #安装常用库
#installManChinese #安装man中文版本
#initCN_UTF8 #设置语言为中文
#initFirewall #关闭selinux,安装iptables
#initSsh #ssh安全设置
#syncSystemTime #同步系统时间加入定时任务
#openFiles #修改文件打开数
#optimizationKernel #优化系统内核参数
#VimSet #vim编辑器设置
#init_safe #ctrl+alt+del 取消重启
#init_rc_local #centos7 rc.local文件执行权限设置
#disableIPV6 #关闭IPV6


#! /bin/sh
#author: vim
#qq:82996821
#filename: CentOS7_auto_opt_set.sh

#set env
export PATH=$PATH:/bin:/sbin:/usr/sbin
export LANG="en_US.UTF-8"
echo "welcome to server" >/etc/issue

#Require root to run this scripts.
if [[ "$(whoami)" != "root"  ]]; then
    echo "Please run this scripts as root." >&2
    exit 1
fi

#define cmd var
SERVICE=`which service`
CHKCONFIG=`which chkconfig`

#Source function library
. /etc/rc.d/init.d/functions

#Config Yum CentOS-Base.repo and epel-release
ConfigYum(){
    echo "#--Config Yum CentOS-Base.repo--"
    cd /etc/yum.repos.d/
    \cp CentOS-Base.repo CentOS-Base.repo.$(date +%F)
    ping -c 1 baidu.com >/dev/null
    [ ! $? -eq 0  ] && echo $"Networking not configured - exiting" && exit 1
    wget -O /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo >/dev/null 2>&1
    yum -y install epel-release >/dev/null 2>&1
    yum clean all >/dev/null 2>&1
    yum makecache >/dev/null 2>&1
    sleep 1
}

#Install Init Packages
installTool(){
    echo "#--Install sysstat lrzsz rsync bash-completion iptables--"
    yum -y install sysstat lrzsz utpdate rsync wget bash-completion iptables-services vim-enhanced net-tools lsof wget lrzsz tree >/dev/null 2>&1
    [ $? -eq 0  ]&&action $"Install Init Packages:" /bin/true||action $"Install Init Packages:" /bin/false
    sleep 1
}

#Install common Packages
installCommTool(){
    echo "#--Install common Packages--"
    yum install -y gcc cmake bzip2-devel curl-devel db4-devel libjpeg-devel libpng-devel freetype-devel libXpm-devel gmp-devel libc-client-devel openldap-devel unixODBC-devel postgresql-devel sqlite-devel aspell-devel net-snmp-devel libxslt-devel libxml2-devel pcre-devel mysql-devel pspell-devel libmemcached libmemcached-devel zlib-devel >/dev/null 2>&1
    [ $? -eq 0  ]&&action $"Install common Packages:" /bin/true||action $"Install common Packages:" /bin/false
    sleep 1
}

#Install man chinese Packages
installManChinese(){
    echo "#--Install man chinese Packages--"
    yum install man-pages-zh-CN.noarch  -y >/dev/null 2>&1
    [ $? -eq 0  ]&&action $"Install man chinese Packages:" /bin/true||action $"Install man chinese Packages:" /bin/false
    sleep 1
}

#Set Charset CN_UTF8
initCN_UTF8(){
    echo "#--set LANG="zh_CN.UTF-8"--"
    \cp /etc/locale.conf /etc/locale.conf.$(date +%F)
    sed -i 's#LANG="en_US.UTF-8"#LANG="zh_CN.UTF-8"#' /etc/locale.conf
    source /etc/locale.conf
    [ `grep zh_CN.UTF-8 /etc/locale.conf|wc -l` -eq 1  ]&&action $"Set Charset CN_UTF8:" /bin/true||action $"Set Charset CN_UTF8:" /bin/false
    sleep 1
}

#Close Selinux and Iptables
initFirewall(){
    echo "#--Close Selinux and Iptables--"
    \cp /etc/selinux/config /etc/selinux/config.`date +"%Y-%m-%d_%H:%M:%S"`
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
    setenforce 0
    systemctl stop firewalld.service
    systemctl disable firewalld.service
    systemctl stop iptables.service
    systemctl status iptables.service
    grep SELINUX=disabled /etc/selinux/config
    echo "Close selinux->OK andy iptables->OK"
    sleep 1
}

initSsh(){
    echo "#--sshConfig--#"
    \cp /etc/ssh/sshd_config /etc/ssh/sshd_config.$(date +%F%T)
    sed -i 's%#Port 22%Port 1020%' /etc/ssh/sshd_config
    sed -i 's%#PermitRootLogin yes%PermitRootLogin no%' /etc/ssh/sshd_config
    sed -i 's%#PermitEmptyPasswords no%PermitEmptyPasswords no%' /etc/ssh/sshd_config
    sed -i 's%#UseDNS yes%UseDNS no%' /etc/ssh/sshd_config
    egrep "UseDNS|1020|^PermitRootLogin|^PermitEmptyPasswords" /etc/ssh/sshd_config
    systemctl restart sshd && action $"--sshConfig--" /bin/true||action $"--sshConfig--" /bin/false
    sleep 1
}

AddSAUser(){
    echo "#--add sys user for all member--"
    datetmp=`date +"%Y-%m-%d_%H-%M-%S"`
    \cp /etc/sudoers /etc/sudoers.${datetmp}
    saUserArr=(user1 user2)
    [ `grep "^sa:" /etc/group |wc -l` -lt 1  ] && groupadd -g 901 sa ||echo "group sa alread exist"
    for((i=0;i<${#saUserArr[@]};i++))
    do
        if [ `grep "${saUserArr[$i]}" /etc/passwd |wc -l` -lt 1  ]; then
           #add sys user
           useradd -g sa -u 90${i} ${saUserArr[$i]}
           #set passwd
           echo "${saUserArr[$i]}123456!@#$%^"|passwd ${saUserArr[$i]} --stdin
           #set sudo power
        else
           echo "user ${saUserArr[$i]} alread exist"
        fi
    done
        [ `grep "\%sa" /etc/sudoers |wc -l` -ne 1  ] && echo "%sa ALL=(ALL)  NOPASSWD: ALL" >>/etc/sudoers
        /usr/sbin/visudo -c
        [ $? -ne 0  ] && /bin/cp /etc/sudoers.${datetmp} /etc/sudoers && echo $"Sudoers not config"
        action $"#--add sys user for all member-->OK" /bin/true
        sleep 1
}

syncSystemTime(){
    echo "#--set system time syn--"
    if [ `grep /usr/sbin/ntpdate /var/spool/cron/root |grep -v grep |wc -l` -lt 1  ]; then
        echo "*/5 * * * * /sbin/ntpdate cn.pool.ntp.org >/dev/null 2>&1" >> /var/spool/cron/root
    fi
}

openFiles(){
    echo "#--set openFiles Num 65535--"
    \cp /etc/security/limits.conf /etc/security/limits.conf.$(date +%F_%T)
    if [ `grep -P "\*\t\t-\tnofile\t\t65535" /etc/security/limits.conf|wc -l` -lt 1 ]; then
    sed -i '/# End of file/i\*\t\t-\tnofile\t\t65535' /etc/security/limits.conf
    ulimit -HSn 65535
    fi
    echo "set maxnum openfiles successful"
    sleep 1
}

#OPT system kernel
optimizationKernel(){
    echo "#--Optimization kernel--"
    \cp /etc/sysctl.conf /etc/sysctl.conf.$(date +%F_%T)
    if [ `grep "net.ipv4.ip_local_port_range = 1024 65535" /etc/sysctl.conf |wc -l` -lt 1 ]; then
cat >>/etc/sysctl.conf<<EOF
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
    echo "modprobe bridge" >> /etc/rc.local
    sysctl -p >/dev/null 2>&1
    /sbin/sysctl -p && action $"Kernel OPT:" /bin/true ||action $"Kernel OPT:" /bin/false
    sleep 1
}

#Vim set
VimSet(){
    echo "#--Vim set--"
    \cp /root/.vimrc /root/.vimrc.$(date +%F_%T)
cat >>/root/.vimrc<<EOF
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
hi CursorLine   cterm=NONE ctermbg=blue ctermfg=white guibg=blue guifg=white
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
inoremap ' ''<ESC>i
EOF
}

init_safe(){
    echo "#--forbid ctrl+alt+del reboot system---"
    \rm -f /usr/lib/systemd/system/ctrl-alt-del.target
    /sbin/init q
    [ $? -eq 0  ]&&action $"forbid ctrl+alt+del reboot system:" /bin/true||action $"forbid ctrl+alt+del reboot system" /bin/false
    sleep 1
}

init_rc_local(){
    echo "#--to /etc/rc.local execute permissions---"
    chmod +x /etc/rc.d/rc.local
    [ $? -eq 0  ]&&action $"to /etc/rc.local execute permissions:" /bin/true||action $"to /etc/rc.local execute permissions:" /bin/false
    sleep 1
}

disableIPV6(){
    echo "#--forbid use IPV6--"
    \cp  /etc/sysctl.conf /etc/sysctl.conf.$(date +%F_%T)
    cat >>/etc/sysctl.conf<<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    [ $? -eq 0  ]&&action $"forbid use IPV6:" /bin/true||action $"forbid use IPV6:" /bin/false
    sysctl -p
    sleep 1
}

AStr="Disable iptables selinux nouseful and forbid ctrl+alt+del reboot system"
BStr="Set sshConfig and change port 22->1020 and forbid root login"
CStr="Add group SA users and edit sudoers"
DStr="Update system time for cron"
EStr="Optization system kernel"
FStr="Install zabbix tools"
GStr="Disable IPV6"
HStr="Edit sysopenfile num to 65535"
IStr="Install Common tools"
JStr="Install common devel"
KStr="Vim set for root"
LStr="One key init install"
QStr="Quit"

echo "###############################################################"
echo "<========================@system init@========================>"
echo "A --${AStr}"
echo "B --${BStr}"
echo "C --${CStr}"
echo "D --${DStr}"
echo "E --${EStr}"
echo "F --${FStr}"
echo "G --${GStr}"
echo "H --${HStr}"
echo "I --${IStr}"
echo "J --${JStr}"
echo "K --${KStr}"
echo "L --${LStr}"
echo "Q --${QStr}"
echo "------------------------------------------------"
echo "Note: after 20s will select one key init install"

option="-1"
read -n1 -t20 -p "Choose one of A-B-C-D-E-F-G-H-I-J-K-L:::" option

flag1=$(echo $option|egrep "\-1"|wc -l)
flag2=$(echo $option|egrep "[A-La-l]"|wc -l)

if [ $flag1 -eq 1  ]; then
    option="k"
elif [ $flag2 -ne 1  ]; then
    echo "Pls input A--->K letter"
    exit 1
fi

echo -e "\nyour choose is: $option\n"
echo "after 5s start install......"
sleep 5
case $option in
    A|a)
      ConfigYum
      #initCN_UTF8
      initFirewall
      init_safe
      init_rc_local
    ;;
    B|b)
      initSsh
    ;;
    C|c)
      AddSAUser
    ;;
    D|d)
      syncSystemTime
    ;;
    E|e)
      optimizationKernel
    ;;
    F|f)
      #init_zabbix_agent
      echo "this function cannot execute yet!"
    ;;
    G|g)
      disableIPV6
    ;;
    H|h)
      openFiles
    ;;
    I|i)
      installTool
    ;;
    J|j)
      installCommTool
    ;;
    K|k)
      VimSet
    ;;   
    L|l)
      installTool
      ConfigYum
      #initCN_UTF8
      initFirewall
      #initService
      initSsh
      AddSAUser
      syncSystemTime
      openFiles
      optimizationKernel
      init_safe
      init_rc_local
      disableIPV6
    ;;
    Q|q)
      exit
    ;;
    *)
      echo "Please input A-L,thank you!"
      exit 1
    ;;
esac
