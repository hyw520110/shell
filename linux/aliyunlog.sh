dt=$(date -d "now" +%Y-%m-%d)
time=$(date  +%H:%M:%S)
echo $start
read -p "查询最近N天(回车默认最近1天):" num
expr $num + 1 >/dev/null 2>&1
[ $? -ne 0 ] && num=1

start=$(date -d "$dt -$num day " +%Y-%m-%d)


aliyunlog log get_log_all --project="lianxin-pro" --logstore="lianxin-pip" --query="\"] ERROR \"" --from_time="$start $time+08:00" --to_time="$dt $time+08:00" --region-endpoint="cn-hangzhou.log.aliyuncs.com" --format-output=no_escape --jmes-filter="join('\n', map(&to_string(@), @))" >> ~/Downloads/pip_error.log
