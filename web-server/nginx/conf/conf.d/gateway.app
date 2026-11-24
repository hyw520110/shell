# Java Gateway 双节点滚动发布上游。
# 两个节点常态同时服务；Jenkins 每次只重启一台，Nginx 将失败请求转给另一台。
upstream gateway {
    least_conn;
    server 192.168.1.5:8000 weight=1 max_fails=1 fail_timeout=5s;
    server 192.168.1.6:8000 weight=1 max_fails=1 fail_timeout=5s;

    # 长连接数 
    keepalive 64;
}
