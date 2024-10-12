#!/bin/bash
#yum=`yum -y install fontconfig sshpass`
#ziti=`mkdir -p /usr/share/fonts/chinese/ && sshpass -p 'lianxin@123' scp -r -o StrictHostKeyChecking=no root@10.1.120.98:/usr/share/fonts/chinese/* /usr/share/fonts/chinese/`
ls -la /usr/share/fonts/chinese/|grep -i "s"
if [ $? -ne 0 ]; then
    echo "正在安装字体"
   # ${yum} ${ziti}
yum -y install fontconfig sshpass
mkdir -p /usr/share/fonts/chinese/ && sshpass -p 'lianxin@123' scp -r -o StrictHostKeyChecking=no root@10.1.120.98:/usr/share/fonts/chinese/* /usr/share/fonts/chinese/
else
    echo "已安装字体"
fi

fc-list :lang=zh
if [ $? -eq 0 ]; then
    echo "  "
else
    echo "字体安装失败，请手动安装"
fi

