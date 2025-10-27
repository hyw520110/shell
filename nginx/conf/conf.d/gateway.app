# 统一的上游服务器配置
upstream gateway {
    # 主服务器
    server 192.168.0.103:7080 weight=1;
    # 备用服务器，其他server都忙或故障时自动切换到当前备用server
    # server 192.168.0.102:7080 weight=1 backup;
    # server 192.168.0.101:7080 weight=2 max_fails=3 fail_timeout=15;
    # max_fails最大失败次数;fail_timeout失败时间;max_conns属性单个服务器的最大连接数 

    # 长连接数 
    keepalive 32;

    # 负载均衡策略，默认轮询
    # ip_hash;  # 如需基于IP的会话保持可启用
    # 响应时间
    # fair;  # 需要第三方模块
    # url_hash;  # 需要第三方模块
}
