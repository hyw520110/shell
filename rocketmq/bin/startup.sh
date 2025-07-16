#!/bin/bash

BASE_DIR=`cd $(dirname $0)/..
BIN=$BASE_DIR/bin
CONF=$BASE_DIR/conf/2m-2s-sync
CLUSTER='10.15.1.18:9876;10.15.1.19:9876'
stty erase "^H" 
StartNamesvc () {
	 sh $BIN/mqnamesrv & 
}
StartBroker (){
     cat <<EOF                        
|****Please Enter Your Choice:[1-3]****|
----------------------------------------
(1) 启动broker-a-m
(2) 启动broker-b-s
(3) 退出
EOF
read -p "Please enter your choice[0-3]: " input
case "$input" in
    1)
	sh $BIN/mqbroker -c $CONF/broker-a.properties &
        ;;

    2)
	sh $BIN/mqbroker -c $CONF/broker-b-s.properties &
        ;;
    3)
        break
        ;;
    esac

}
Stop        (){
	cat <<EOF
|****Please Enter Your Choice:[1-3]****|
----------------------------------------
(1) 停止broker
(2) 停止namesrv、broker
(3) 退出
EOF
        read -p "Please enter your choice[0-3]: " input1

    case "$input1" in
    1)
       $BIN/mqshutdown broker
        ;;

    2)
        $BIN/mqshutdown namesrv
	$BIN/mqshutdown broker
        ;;
    3)
        break
        ;;
    esac
}
clusterList (){
	   sh $BIN/mqadmin clusterList -n $CLUSTER
}

topicList   (){
	   sh $BIN/mqadmin topicList -n $CLUSTER
}

consumerProgress  (){
	   sh $BIN/mqadmin consumerProgress -n $CLUSTER
}

topicStatus (){
   clear  && read -p  "Please input the topic name :" input
	if [ ! -n $input ];then
           echo "please input the correct topicname"
	elif [ -n $input ];then
           sh $BIN/mqadmin topicStatus topicList -n $CLUSTER -t  $input
	fi
}

updateTopic (){
   clear  && read -p  "Please input the topic name what you want to create :" input
        if [ ! -n $input ];then
           echo "please input correct "
        elif [ -n $input ];then
           sh $BIN/mqadmin updateTopic -c rocketmq-ztqy-test -n $CLUSTER -t $input 
        fi
}

deleteTopic (){
   clear  && read -p  "Please input the topic name what you want to delete :" input
        if [ ! -n $input ];then
           echo "please input correct "
        elif [ -n $input ];then
           sh $BIN/mqadmin updateTopic -c rocketmq-ztqy-test -n $CLUSTER -t $input
        fi
}

updateSubGroup (){
   clear  && read -p  "Please input the Group name what you want to create :" input
        if [ ! -n $input ];then
           echo "please input correct "
        elif [ -n $input ];then
	sh $BIN/mqadmin updateSubGroup -c rocketmq-ztqy-test -n $CLUSTER -g $input
	fi
}

deleteSubGroup (){
   clear  && read -p  "Please input the Group name what you want to delete :" input
        if [ ! -n $input ];then
           echo "please input correct "
        elif [ -n $input ];then
           sh $BIN/mqadmin deleteSubGroup -c rocketmq-ztqy-test -n $CLUSTER -g $input
        fi                
}    

statsAll(){
           sh $BIN/mqadmin statsAll  -n $CLUSTER -a
}

Msgid   (){
	   clear  && read -p  "Please input the Msgid :" input
	   sh $BIN/mqadmin queryMsgByid -n  $CLUSTER  -i $input
}


case "$1" in
        clusterList)
		clusterList
                ;;
        topicList)
                topicList
                ;;
        consumerProgress)
		consumerProgress
                ;;
        topicStatus)
		topicStatus
                ;;
	updateTopic)
		updateTopic
		;;
	deleteTopic)
		deleteTopic
		;;
	updateSubGroup)
		updateSubGroup
		;;
	deleteSubGroup)
		deleteSubGroup
		;;
	statsAll)
		statsAll
		;;
	Msgid)
		Msgid
		;;
	startsvc)
	StartNamesvc  
		;;
	start)
	 StartBroker
		;;
	stop)
	Stop
	;;
        help|*)
		clear
                echo $"Usage: $0 {clusterList|topicList|consumerProgress|topicStatus|updateTopic|deleteTopic|updateSubGroup|deleteSubGroup|statsAll|help}"
                cat <<EOF

                        clusterList     - 查询集群状态
                        topicList       - 查看集群中的topic信息
                        consumerProgress- 查看所有消费进度
                        topicStatus	- 查看Topic状态
			updateTopic	- 创建/更新topic
			deleteTopic	- 删除topic
			updateSubGroup	- 创建/更新消费组
			deleteSubGroup  - 删除消费组
			statsAll	- 查看Topic订阅关系、TPS、积累量、24h读写总量等信息
                        help            - this screen

EOF
        exit 1
        ;;
esac

exit 0
