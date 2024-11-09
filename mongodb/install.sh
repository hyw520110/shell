#!/bin/bash
# 脚本名称：MongoDB安装脚本
# https://www.mongodb.com/zh-cn/docs/database-tools/installation/installation-linux/
# https://downloads.mongodb.com/compass/mongodb-mongosh_2.3.3_arm64.deb
# https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian10-x86_64-100.10.0.tgz
# 默认安装目录
INSTALL_DIR="/opt/mongodb"
# 下载目录：本地安装包不存在时，下载安装包的目录
DOWNLOAD_DIR="/opt/softs"
# 配置文件路径
CONF_FILE=${INSTALL_DIR}/mongo/conf/mongodb.conf
# 自启服务文件
SERVICE_FILE=/etc/systemd/system/mongodb.service
# 环境变量文件
ENV_FILE=/etc/profile.d/mongo.sh
# 进程服务及目录所属用户及用户组
USR=mongodb
GROUP=mongodb
# 默认端口
PORT=27017

# 导入公共脚本
source ../shell/os_common.sh

find_and_extract_mongodb_binary() {
    tgz_files_current=$(ls mongodb*.tgz 2>/dev/null)
    tgz_files_download=$(ls ${DOWNLOAD_DIR}/mongodb*.tgz 2>/dev/null)
    # 查找当前目录和下载目录下是否有安装包
    tgz_files=$(echo "$tgz_files_current $tgz_files_download" | tr ' ' '\n' | sort -u | tr '\n' ' '|xargs)
    while true; do
        if [ "$(echo $tgz_files | wc -w)" -gt 1 ]; then
            echo "找到多个 MongoDB 二进制文件，请选择:"
            for i in $(echo "$tgz_files"); do
                echo "$i"
            done
            read -t 5 -p "请输入数字选择一个: " choice
            if [ "$choice" -lt 1 ] || [ "$choice" -gt "$(echo $tgz_files | wc -w)" ]; then
                echo "无效的选择，请重新输入."
                continue
            else
                tgz_files=$(echo "$tgz_files" | sed -n "${choice}p")
                break
            fi
        fi
        if [ ! -f "$tgz_files" ]; then
            read -t 8 -p "未找到MongoDB二进制文件，请输入本地路径 (或按Enter自动下载): " tgz_path
            if [ -z "$tgz_path" ]; then
                tgz_files=$(download_binary)
                break
            elif [ ! -f "$tgz_path" ]; then
                echo "指定的路径不存在，请重新输入."
                continue
            else
                tgz_files="$tgz_path"
                break
            fi
        else
            break
        fi
    done
   if [ ! -f "$tgz_files" ]; then
      echo "查找或下载失败，退出脚本。"
      exit 1
    fi
    echo "解压:${tgz_files}到${INSTALL_DIR}" && tar -zxf $tgz_files -C ${INSTALL_DIR}
    folder_name=$(ls ${INSTALL_DIR} | grep -E '^mongodb-.*' | tail -1)
    mv "${INSTALL_DIR}/$folder_name" ${INSTALL_DIR}/mongo
    echo "解压完成:${INSTALL_DIR}/mongo"
}
download_binary() {
    local tgz_files="${DOWNLOAD_DIR}/mongodb-linux.tgz"
    if [ -f $tgz_files ]; then
        echo "$tgz_files"
        return
    fi
    arch="x86_64"
    local distro=$(get_distro_version)
    wget -O $tgz_files "https://fastdl.mongodb.org/linux/mongodb-linux-${arch}-${distro}-6.0.16.tgz" && echo "$tgz_files" || echo ""
}
configure_env_var() {
    [ ! -f $ENV_FILE ] && echo 'export PATH=$PATH:${INSTALL_DIR}/mongo/bin' >> $ENV_FILE
    source $ENV_FILE
}

create_dirs() {
    if [ ! -d "${INSTALL_DIR}/mongo/db" ] || [ ! -d "${INSTALL_DIR}/mongo/logs" ]; then
      mkdir -p ${INSTALL_DIR}/mongo/{db,logs,conf}
    fi
    [ ! -f ${INSTALL_DIR}/mongo/mongodb.pid ] && touch ${INSTALL_DIR}/mongo/mongodb.pid && chmod 600 ${INSTALL_DIR}/mongo/*.pid
    create_user_and_group $USR $GROUP
    chown -R $USR:$GROUP ${INSTALL_DIR}/mongo
    chmod -R 755 ${INSTALL_DIR}/mongo
    chmod -R 700 ${INSTALL_DIR}/mongo/db ${INSTALL_DIR}/mongo/logs ${INSTALL_DIR}/mongo/conf
}

ask_for_replica_set() {
    read -t 3 -p "是否启用副本集? (y/n) 默认(y): " use_replica_set
    use_replica_set=${use_replica_set:-y}
    if [ "$use_replica_set" == "n" ]; then
        echo ""
    else
        read -t 5 -p "请输入副本集名称 (默认为 rs0): " replica_set_name
        replica_set_name=${replica_set_name:-rs0}
        echo "$replica_set_name"
    fi
}
create_mongodb_conf() {
    create_dirs
    replica_set_name=$(ask_for_replica_set)
    keyfile_path=$(generate_keyfile ${INSTALL_DIR}/mongo/conf/mongodb.key)
    [ -f $keyfile_path ] && chmod 400 $keyfile_path
    data_dir="${INSTALL_DIR}/mongo/db"
    cat <<EOF > $CONF_FILE
net:
  port: $PORT
  # 127.0.0.1只允许本机访问，如果想让其他主机能访问修改为0.0.0.0
  bindIp: 0.0.0.0
storage:
  dbPath: ${data_dir}
  journal:
    enabled: true
processManagement:
  fork: true
  pidFilePath: ${INSTALL_DIR}/mongo/mongodb.pid
systemLog:
  destination: file
  logAppend: true
  path: ${INSTALL_DIR}/mongo/logs/mongodb.log
# 认证配置在初始化副本集和初始用户后开启
#security:
#  authorization: enabled
#  keyFile: $keyfile_path
EOF
    if [ -n "$replica_set_name" ]; then
      echo "replication: " >> $CONF_FILE
      echo "  replSetName: $replica_set_name" >> $CONF_FILE

      local ports=(27018 27019 27020)
      for p in "${ports[@]}"; do
        cp $CONF_FILE ${INSTALL_DIR}/mongo/conf/mongodb_${p}.conf
        local conf_file="${INSTALL_DIR}/mongo/conf/mongodb_${p}.conf"
        local log_file="${INSTALL_DIR}/mongo/logs/mongodb${p}.log"
        local data_dir="${INSTALL_DIR}/mongo/db/${p}"
        [ ! -d $data_dir ] && mkdir $data_dir
        sed -i  "s#${PORT}#$p#g" $conf_file
        sed -i  "s#${INSTALL_DIR}/mongo/logs/mongodb.log#$log_file#g" $conf_file
        sed -i  "s#${INSTALL_DIR}/mongo/db#$data_dir#g" $conf_file
        sed -i  "s#mongodb.pid#mongodb${p}.pid#g" $conf_file
      done
    fi
    chown $USR:$GROUP -R ${INSTALL_DIR}/mongo
}
create_systemd_service() {
    cat <<EOF > $SERVICE_FILE
[Unit]
Description=MongoDB Database Server
After=network.target

[Service]
Type=forking
User=$USR
Group=$GROUP
ExecStart=${INSTALL_DIR}/mongo/bin/mongod --config $CONF_FILE
PIDFile=${INSTALL_DIR}/mongo/mongodb.pid
Restart=on-failure
LimitNOFILE=65536
TimeoutStartSec=130

[Install]
WantedBy=multi-user.target
EOF
    count=$(find $INSTALL_DIR/mongo/conf/ -name "mongodb_*.conf"|wc -l)
    if [ $count -eq 0 ];then
      count=$(find $INSTALL_DIR/mongo/conf/ -name "mongodb*.conf"|wc -l)
    fi
    systemctl daemon-reload
    if [ $count -le 1 ];then
      systemctl enable mongodb
      if systemctl is-active mongodb &> /dev/null; then
          echo -e "${GREEN}MongoDB 服务正在运行。${NC}"
      else
          systemctl start mongodb
      fi
      systemctl status mongodb
    else
      systemctl disable mongodb
      local ports=(27018 27019 27020)
      for p in "${ports[@]}"; do
        local file="/etc/systemd/system/mongodb${p}.service"
        cp $SERVICE_FILE $file
        sed -i "s#mongodb.conf#mongodb_${p}.conf#g" $file
        sed -i "s#\.pid#${p}\.pid#g" $file
        systemctl enable mongodb${p}
        systemctl start mongodb${p}
      done
    fi
}
validate_login() {
    local result=""
    local retries=3
    echo "mongosh $1 --username $2 --password $3 --authenticationDatabase admin 登录验证..."
    while [ $retries -gt 0 ]; do
      sleep 5
      # https://www.mongodb.com/try/download/shell
      if mongosh $1 --username "$2" --password "$3" --authenticationDatabase "admin" --eval "db.runCommand({connectionStatus: 1})"; then
        result="$2用户登录成功。"
        break
      else
        echo "重试验证..."
        result="$2用户登录失败。"
      fi
      retries=$((retries - 1))
    done
    echo "$result"
}
init_mongodb() {
  # 初始化时通常端口小在先，通常为主节点
  local addr="mongodb://localhost:27018/admin"
  local host_name=$(get_dns_hostname)
  grep -q "replSetName:" $CONF_FILE || addr="mongodb://localhost:27017/admin"
  echo -n "${addr}等待接受连接..."
  wait_sec=60
  if wait_for_process_ready $wait_sec "mongosh $addr --eval 'db.runCommand({connectionStatus: 1});'"; then
    echo "已准备好接受连接。"
  else
    echo "未能在${wait_sec}秒内准备好接受连接。"
  fi
  if grep -q "replSetName:" $CONF_FILE;then
    replSetName=$(cat $INSTALL_DIR/mongo/conf/*.conf |grep "replSetName:"|head -n 1|awk -F': ' '{print $2}')
    mongosh $addr <<EOF
rs.initiate(
  {
    _id: "$replSetName",
    members: [
      { _id: 0, host: "$host_name:27018" },
      { _id: 1, host: "$host_name:27019" },
      { _id: 2, host: "$host_name:27020" }
    ]
  }
);
EOF

    if wait_for_process_ready $wait_sec "mongosh $addr --eval 'rs.status();'|grep -q "PRIMARY""; then
      mongosh $addr --eval 'rs.status();'|grep -B 3 "PRIMARY"|grep "name: "|awk '{print $2}'
    fi
  fi

  read -t 5 -p "输入初始用户名(默认root):" username
  username=${username:-root}
  if ! mongosh $addr --eval "print(db.system.users.findOne({user: '$username', db: 'admin'}))" | grep -q "$username"; then
      password=$(tr -dc 'a-zA-Z0-9#&' < /dev/urandom | head -c12)
      echo "创建初始用户 '$username'..." && echo -e "初始密码:${RED}${password}${NC}"
      mongosh $addr --eval "db.createUser({user: '$username', pwd: '$password', roles: [{role: 'root', db: 'admin'},{role: 'clusterAdmin', db: 'admin'}]});"
      validate_login $addr $username $password
  else
      echo "用户 '$username' 已存在，跳过创建。"
  fi

  echo "开启认证并重启服务..."
  local ports=(27018 27019 27020)
  grep -q "replSetName:" $CONF_FILE || ports=(27017)
  for p in "${ports[@]}"; do
    local conf_file="${INSTALL_DIR}/mongo/conf/mongodb_${p}.conf"
    [ ! -f $conf_file ] && conf_file="${INSTALL_DIR}/mongo/conf/mongodb.conf"
    if [ ! -f $conf_file ];then
      echo "文件不存在:$conf_file"
      continue
    fi
    sed -i 's/^#security:/security:/' $conf_file
    sed -i 's/^#  authorization/  authorization/' $conf_file
    sed -i "s/#  keyFile/  keyFile/" $conf_file
  done
  if grep -q "replSetName:" $CONF_FILE;then
    for p in "${ports[@]}"; do
      echo "systemctl restart mongodb${p}" && systemctl restart mongodb${p}
    done
    echo "已重启，等待启动完成..."
    if wait_for_process_ready $wait_sec "mongosh $addr -u $username -p '$password' --eval 'rs.status();'|grep -q 'PRIMARY'"; then
      echo -e "\n启动完成，副本集：\n" && mongosh $addr -u $username -p "$password" --eval 'rs.status();'
      # db.changeUserPassword("username", "new_password")
    fi
  else
     systemctl restart mongodb
  fi
}
detect_mongodb() {
      if ! grep -q "replSetName:" $CONF_FILE; then
        sleep 5
        if pgrep -x "mongod" > /dev/null; then
          echo -e "${GREEN}MongoDB安装成功！${NC}"
          echo -e "注意：
          执行: source $ENV_FILE 或【重新登录当前服务器】来重新加载环境变量
          日志文件： ${INSTALL_DIR}/mongo/logs/mongodb.log
          启动命令: systemctl start mongodb
          停止命令：systemctl stop mongodb
          端口号：$PORT
          "
        else
            echo -e "${RED}很抱歉安装失败${NC}"
        fi
      fi
}
check_permission
# 调试代码，方便脚本重复执行
rm -rf ${INSTALL_DIR}/mongo
if ! command -v "mongosh" &> /dev/null; then
  echo "安装mongosh:https://www.mongodb.com/try/download/shell"
fi
install_dependencies
find_and_extract_mongodb_binary
configure_env_var
create_mongodb_conf
create_systemd_service
init_mongodb
detect_mongodb
detect_firewall $PORT

