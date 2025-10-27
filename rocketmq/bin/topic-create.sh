
[ ! -n "$1" ] && echo "usage:$0 \$topic" && exit 1
ip=`/opt/shell/ip.sh`
name=`cat ../conf/broker.conf |grep brokerClusterName|awk -F'=' '{print $2}' `
echo "$ip cluster name:$name"
./mqadmin updateTopic -n $ip:9876 -c $name -t $1
