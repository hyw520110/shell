export NAMESRV_ADDR=localhost:9876
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
$DIR/tools.sh org.apache.rocketmq.example.quickstart.Producer
