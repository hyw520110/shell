#!/bin/bash
# docker和docker-compose自动安装、配置

f=/usr/local/bin/docker-compose

#判断docker是否安装，已安装输出docker版本，如docker未安装先安装docker
if [ `docker -v 2>/dev/null |grep version|grep -v grep |wc -l` -gt  0 ]; then
   docker -v 
   echo -e "docker已安装,如需卸载，执行：\nyum -y remove docker docker-client docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine docker-engine-selinux docker-client-latest docker-common docker-ce-cli && rm -rf /etc/docker /run/docker  /var/lib/docker /usr/libexec/docker"
   #rpm -e `rpm -qa | grep docker`
else
   # docker安装
   yum install -y yum-utils device-mapper-persistent-data lvm2
   # wget https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo -O /etc/yum.repos.d/docker-ce.repo
   yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
   # yum list docker-ce --showduplicates
   version=`cat /etc/redhat-release 2>/dev/null|sed -r 's/.* ([0-9]+)\..*/\1/'`
   echo "version:[$version]"
   if [ $version -eq 7 ]; then
        sudo yum makecache fast
   elif [ $version -eq 8 ]; then
        sudo dnf makecache
   fi
   yum install -y docker-ce docker-ce-cli containerd.io 
   # yum install -y --setopt=obsoletes=0 docker-ce-3:18.09.9-3.el7 docker-ce-cli-1:18.09.9-3.el7 containerd.io 
   systemctl enable docker
   systemctl start docker
   # docker配置
   if [ ! -d /etc/docker ];then
     mkdir -p /etc/docker
     cat > /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": ["http://hub-mirror.c.163.com","https://docker.mirrors.ustc.edu.cn","https://reg-mirror.qiniu.com","http://f1361db2.m.daocloud.io"]
}
EOF
     systemctl daemon-reload
     systemctl restart docker
   fi
fi
# 安装docker-compose
if [ ! -f $f ];then
	#sudo curl -L https://get.daocloud.io/docker/compose/releases/download/v2.11.1/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
	url=https://github.com/docker/compose/releases/download/v2.11.1/docker-compose-`uname -s`-`uname -m`  && echo $url && curl -L $url -o $f && chmod +x $f
fi
