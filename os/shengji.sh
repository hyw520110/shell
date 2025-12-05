#!/bin/bash
tishi='请输入以下按键：
1是系统审计设置
2是检查空口令账号
3是检查超级用户
4是查看可登录用户密码有效期
5是查看可登录用户
6是查看最近10次登录失败记录，以及10次登录成功的记录
7是查看系统是否有错误
8是系统优化
9是退出终端'
PS3="请输入你的选项："
printf "$tishi \n"
foods=("1" "2" "3" "4" "5" "6" "7" "8" "9")

select fav in "${foods[@]}"; do
  qwe=----------------------------------------------------------------------------------------------------------------------------------
  case $fav in
    "1")
      #时间
      result=`date`
      echo "该脚本执行的时间为：$result"
      echo -e "\e[1;34m $qwe \e[0m"
      #设置history时间
      echo 'HISTTIMEFORMAT="%F %T "' >>/root/.bash_profile
      echo 'export HISTTIMEFORMAT' >>/root/.bash_profile
      source /root/.bash_profile
      echo "正在设置历史命令时间查询请稍后！！！！！"
      echo -e "\e[1;35m $qwe \e[0m"
      #设置登陆失败锁定密码错5次则十分钟后才能登录
      echo "正在设置登陆失败锁定请稍后！！！"
      sed -i '1a\auth required pam_tally2.so deny=3 unlock_time=5 even_deny_root root_unlock_time=10' /etc/pam.d/sshd
      echo -e "\e[1;32m $qwe \e[0m"
      #设置会话超时
      printf "正在设置会话超时，时间为300秒，请稍后！！！\n"
      echo -e "\e[1;32m $qwe \e[0m"
      ;;
    "2")
      #检查空口令账号
      empty_pw_user=`awk -F:  '($2 == "") { print $1 }' /etc/shadow`
      echo "检查空口令账号为:$empty_pw_user"
      echo -e "\e[1;36m $qwe \e[0m"
    ;;
    "3")
      #检查超级用户为
      super_user=`awk -F: '($3==0) { print $1}' /etc/passwd|grep -v "root"`
      echo "检查超级用户为（除root以外)：$super_user"
      echo -e "\e[1;37m $qwe \e[0m"
      ;;
    "4")
      #查看可登录用户密码有效期
      for user in $(cat /etc/passwd | grep -v /sbin/nologin | cut -d : -f 1 ) ;
      do
      echo $user;
      chage -l $user;
      done
      echo -e "\e[1;33m $qwe \e[0m"
      ;;
    "5")
      #查看可登录用户
      View_loginable_users=`cat /etc/passwd | grep -v /sbin/nologin | cut -d : -f 1 `
      echo "可登录用户为：$View_loginable_users"
      echo -e "\e[1;31m $qwe \e[0m"
      ;;
    "6")
      #查看登录记录
      shibai=`lastb |tail -10`
      chenggong=`last | tail -10`
      printf "最近10成功登录的信息如下: \n $chenggong"
      echo -e "\e[1;36m $qwe \e[0m"
      printf "最近10次登录失败的信息如下: \n $shibai"
      echo -e "\e[1;31m $qwe \e[0m"
      ;;
    "7")
      #查看系统版本以及是否有错误信息
      banben=`lsb_release -a`
      dmesg=`dmesg | grep -i error`
      printf "系统版本信息如下： \n $banben"
      echo -e "\e[1;36m $qwe \e[0m"
      printf "系统错误信息如下： \n $dmesg"
      ;;
    "8")
      sed -i 's#^SELINUX=.*#SELINUX=disabled#g' /etc/selinux/config
      if [ "$?" -eq 0 ];then
              echo "永久关闭selinux模块成功！"
              echo -e "\e[1;36m $qwe \e[0m"
              else
              echo "对不起，永久关闭selinux失败，请检查脚本或者手动关闭selinux！"
              echo -e "\e[1;36m $qwe \e[0m"
              exit 1
      fi
      #关闭防火墙并加入开机自启
      systemctl stop firewalld && systemctl disable firewalld  &> /dev/null
      if [ "$?" -eq 0 ];then
              echo "关闭firewalld防火墙成功！"
              echo -e "\e[1;36m $qwe \e[0m"
              else
              echo "对不起，关闭防火墙失败，请检查脚本或者手动关闭防火墙！"
              echo -e "\e[1;36m $qwe \e[0m"
              exit 1
      fi

      cp /etc/sysctl.conf /etc/sysctl.conf.txt
      cat >>/etc/sysctl.conf <<EOF
      net.ipv4.ip_forward = 1
      net.ipv4.conf.default.rp_filter = 1
      net.ipv4.conf.default.accept_source_route = 0
      kernel.sysrq = 0
      kernel.core_uses_pid = 1
      kernel.msgmnb = 65536
      kernel.msgmax = 65536
      kernel.shmmax = 68719476736
      kernel.shmall = 4294967296
      net.core.wmem_default = 8388608
      net.core.rmem_default = 8388608
      net.core.rmem_max = 16777216
      net.core.wmem_max = 16777216
      net.ipv4.route.gc_timeout = 20
      net.ipv4.tcp_retries2 = 5
      net.ipv4.tcp_fin_timeout = 30
      net.ipv4.tcp_wmem = 8192 131072 16777216
      net.ipv4.tcp_rmem = 32768 131072 16777216
      net.ipv4.tcp_mem = 94500000 915000000 927000000
      net.core.somaxconn = 262144
      net.core.netdev_max_backlog = 262144
      net.core.wmem_default = 8388608
      net.core.rmem_default = 8388608
      net.core.rmem_max = 16777216
      net.core.wmem_max = 16777216
      net.ipv4.route.gc_timeout = 20
      net.ipv4.ip_local_port_range = 10024  65535
      net.ipv4.tcp_retries2 = 5
      net.ipv4.tcp_syn_retries = 2
      net.ipv4.tcp_synack_retries = 2
      net.ipv4.tcp_timestamps = 0
      net.ipv4.tcp_tw_recycle = 1
      net.ipv4.tcp_tw_reuse = 1
      net.ipv4.tcp_keepalive_time = 1800
      net.ipv4.tcp_keepalive_probes = 3
      net.ipv4.tcp_keepalive_intvl = 30
      net.ipv4.tcp_max_orphans = 3276800
      net.ipv4.tcp_wmem = 8192 131072 16777216
      net.ipv4.tcp_rmem = 32768 131072 16777216
      net.ipv4.tcp_mem = 94500000 915000000 927000000

      fs.file-max = 65535
      kernel.pid_max = 65536
      net.ipv4.tcp_wmem = 4096 87380 8388608
      net.core.wmem_max = 8388608
      net.core.netdev_max_backlog = 5000
      net.ipv4.tcp_window_scaling = 1
      net.ipv4.tcp_max_syn_backlog = 10240

      net.core.netdev_max_backlog = 262144
      net.core.somaxconn = 262144
      net.ipv4.tcp_max_orphans = 3276800
      net.ipv4.tcp_max_syn_backlog = 262144
      net.ipv4.tcp_timestamps = 0
      net.ipv4.tcp_syn_retries = 1
      net.ipv4.tcp_synack_retries = 1

      net.ipv4.tcp_syncookies = 1
      net.ipv4.tcp_tw_reuse = 1
      net.ipv4.tcp_tw_recycle = 1
      net.ipv4.tcp_fin_timeout = 30

      net.ipv4.tcp_keepalive_time = 120
      net.ipv4.ip_local_port_range = 10000 65000
      net.ipv4.tcp_max_syn_backlog = 262144
      net.ipv4.tcp_max_tw_buckets = 36000net.ipv4.ip_forward = 1
      net.ipv4.conf.default.rp_filter = 1
      net.ipv4.conf.default.accept_source_route = 0
      kernel.sysrq = 0
      kernel.core_uses_pid = 1
      kernel.msgmnb = 65536
      kernel.msgmax = 65536
      kernel.shmmax = 68719476736
      kernel.shmall = 4294967296
      net.core.wmem_default = 8388608
      net.core.rmem_default = 8388608
      net.core.rmem_max = 16777216
      net.core.wmem_max = 16777216
      net.ipv4.route.gc_timeout = 20
      net.ipv4.tcp_retries2 = 5
      net.ipv4.tcp_fin_timeout = 30
      net.ipv4.tcp_wmem = 8192 131072 16777216
      net.ipv4.tcp_rmem = 32768 131072 16777216
      net.ipv4.tcp_mem = 94500000 915000000 927000000
      net.core.somaxconn = 262144
      net.core.netdev_max_backlog = 262144
      net.core.wmem_default = 8388608
      net.core.rmem_default = 8388608
      net.core.rmem_max = 16777216
      net.core.wmem_max = 16777216
      net.ipv4.route.gc_timeout = 20
      net.ipv4.ip_local_port_range = 10024  65535
      net.ipv4.tcp_retries2 = 5
      net.ipv4.tcp_syn_retries = 2
      net.ipv4.tcp_synack_retries = 2
      net.ipv4.tcp_timestamps = 0
      net.ipv4.tcp_tw_recycle = 1
      net.ipv4.tcp_tw_reuse = 1
      net.ipv4.tcp_keepalive_time = 1800
      net.ipv4.tcp_keepalive_probes = 3
      net.ipv4.tcp_keepalive_intvl = 30
      net.ipv4.tcp_max_orphans = 3276800
      net.ipv4.tcp_wmem = 8192 131072 16777216
      net.ipv4.tcp_rmem = 32768 131072 16777216
      net.ipv4.tcp_mem = 94500000 915000000 927000000

      fs.file-max = 65535
      kernel.pid_max = 65536
      net.ipv4.tcp_wmem = 4096 87380 8388608
      net.core.wmem_max = 8388608
      net.core.netdev_max_backlog = 5000
      net.ipv4.tcp_window_scaling = 1
      net.ipv4.tcp_max_syn_backlog = 10240

      net.core.netdev_max_backlog = 262144
      net.core.somaxconn = 262144
      net.ipv4.tcp_max_orphans = 3276800
      net.ipv4.tcp_max_syn_backlog = 262144
      net.ipv4.tcp_timestamps = 0
      net.ipv4.tcp_syn_retries = 1
      net.ipv4.tcp_synack_retries = 1


      net.ipv4.tcp_syncookies = 1
      net.ipv4.tcp_tw_reuse = 1
      net.ipv4.tcp_tw_recycle = 1
      net.ipv4.tcp_fin_timeout = 30

      net.ipv4.tcp_keepalive_time = 120
      net.ipv4.ip_local_port_range = 10000 65000
      net.ipv4.tcp_max_syn_backlog = 262144
      net.ipv4.tcp_max_tw_buckets = 36000
EOF
      #sysctl  -p
      if [ "$?" -eq 0 ];then
              echo "优化系统内核成功！"
              echo -e "\e[1;36m $qwe \e[0m"
              else
              echo "优化系统内核失败"
              echo -e "\e[1;36m $qwe \e[0m"
              exit 1
      fi
      echo '*        soft    noproc 65535
      *        hard    noproc 65535
      *        soft    nofile 65535
      *        hard    nofile 65535'>>/etc/security/limits.conf
      if [ "$?" -eq 0 ];then
              echo "最大文件打开数优化成功"
              echo -e "\e[1;36m $qwe \e[0m"
              else
              echo "最大文件打开数优化失败"
              echo -e "\e[1;36m $qwe \e[0m"
              exit 1
      fi
      sed -i 's/.*UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
      sed -i 's/.*GSSAPIAuthentication yes/GSSAPIAuthentication no/' /etc/ssh/sshd_config
      if [ "$?" -eq 0 ];then
              echo "ssh优化成功"
              echo -e "\e[1;36m $qwe \e[0m"
              else
              echo "ssh优化失败"
              echo -e "\e[1;36m $qwe \e[0m"
              exit 1
      fi
      systemctl restart sshd
      if [ "$?" -eq 0 ];then
              echo "ssh重启成功"
              echo -e "\e[1;36m $qwe \e[0m"
              else
              echo "ssh重启失败"
              echo -e "\e[1;36m $qwe \e[0m"
      fi
      ;;

  "9")
      echo "退出终端"
      exit
    ;;
    *) echo "无效选项 $REPLY";;
  esac
done
