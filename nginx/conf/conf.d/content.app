
upstream content {
 server 10.1.120.40:9082 weight=1;
 #备用服务器其他server都忙或故障时自动切换到当前备用server
 #server 10.1.120.40:9082 weight=1 backup;
 #server 10.1.120.40:9082 weight=2 max_fails=3 fail_timeout=15;
 #max_fails最大失败次数;fail_timeout失败时间;max_conns属性单个服务器的最大连接数 

 #长连接数 
 #keepalive 16;

 #默认轮询
 #ip_hash;
 #响应时间
 #fair;
 #url_hash;
}
