#!/bin/bash
#nginx加载配置

BASE_DIR=`cd $(dirname $0)/..; pwd`
conf_file=$BASE_DIR/conf/nginx.conf

reload_nginx() {
    if [ -n "`docker ps -a 2>/dev/null|grep nginx|grep Up`" ];then
        isOk=`docker exec -it nginx nginx -t |grep ok `
        [ -n "$isOk" ] && echo $isOk && docker exec -it nginx nginx -s reload
    else
        # 检查nginx命令是否存在
        if command -v nginx >/dev/null 2>&1; then
            NGINX_CMD="nginx"
        else
            # 尝试在常见位置查找nginx
            for path in "/usr/sbin/nginx" "/usr/local/nginx/sbin/nginx" "/opt/nginx/sbin/nginx"; do
                if [ -x "$path" ]; then
                    NGINX_CMD="$path"
                    break
                fi
            done
        fi
        
        # 如果找到了nginx命令
        if [ -n "$NGINX_CMD" ]; then
            # 先测试配置
            if $NGINX_CMD -c $conf_file -t 2>/dev/null; then
                echo "Nginx配置测试通过"
                # 尝试重新加载，如果权限不足则使用sudo
                if $NGINX_CMD -c $conf_file -s reload 2>/dev/null; then
                    echo "Nginx重新加载成功"
                else
                    echo "尝试使用sudo重新加载..."
                    sudo $NGINX_CMD -c $conf_file -s reload
                fi
            else
                echo "Nginx配置测试失败"
                $NGINX_CMD -c $conf_file -t
            fi
        else
            echo "错误: 找不到nginx命令"
            return 1
        fi
    fi
}

# 执行重新加载
reload_nginx