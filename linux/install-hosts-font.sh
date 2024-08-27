#!/bin/bash

# 主机名映射列表
hosts=("redis-server" "mq-server" "mysql-server" "oss-server" "es-server" "model-server" "sk-server" "nacos-server" "task-server" "ssj-show.aipsybot.com" "zk1" "zk2" "zk3")

# 字体备份目录
fonts_backup_dir="/opt/softs/fonts/chinese"

# 获取当前IP地址
ip=$(/opt/shell/ip.sh)

# 更新 /etc/hosts 文件
for host in "${hosts[@]}"; do
    if ! grep -q "$host" /etc/hosts; then
        echo "$ip $host" >> /etc/hosts
    fi
done

# 确保字体备份目录存在
mkdir -p "$fonts_backup_dir"
mkdir -p "/usr/share/fonts/chinese"

# 检查字体是否已安装
if ! ls -A "/usr/share/fonts/chinese/" | grep -iq "s"; then
    echo "正在安装字体..."
    yum -y install fontconfig sshpass

    # 如果字体备份目录为空，则从测试服务器拷贝字体
    if [ -z "$(ls -A "$fonts_backup_dir")" ]; then
      # 用户输入备份服务器信息
      echo "请输入备份服务器的 IP 地址（默认超时 8 秒）："
      read -t 8 -p "IP: " backup_ip
      echo "请输入备份服务器的用户名："
      read -p "Username: " backup_username
      echo "请输入备份服务器的密码："
      read -s -p "Password: " backup_password
      echo

      # 检测输入的 IP 地址是否可达
      ping -c 1 "$backup_ip" > /dev/null 2>&1
      if [ $? -ne 0 ]; then
          echo "错误：输入的 IP 地址 $backup_ip 不可达！"
          exit 1
      else
          sshpass -p '$backup_password' scp -r -o StrictHostKeyChecking=no $backup_username@$backup_ip:/usr/share/fonts/chinese/* "$fonts_backup_dir/"
      fi
    fi
else
    echo "已安装字体"
fi

# 如果字体备份目录为空，则从系统字体目录备份到字体备份目录
if [ -z "$(ls -A "$fonts_backup_dir")" ]; then
    find /usr/share/fonts/chinese/ -iname "s*" -exec cp --parents {} "$fonts_backup_dir/" \;
fi

# 检查字体是否已配置
if ! fc-list :lang=zh; then
    echo "字体安装失败，请手动安装"
else
    echo "字体安装成功"
fi