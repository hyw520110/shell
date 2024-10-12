#!/bin/bash
# top -n 参数指定运行次数，1代表运行一次即停止，不再等待top数据更新，使用awk指定分割符，提取数据
#cpu_us=`top -n 1 | grep 'Cpu(s)' | awk -F'[" "%]+' '{print $2}'`
#cpu_sy=`top -n 1 | grep 'Cpu(s)' | awk -F'[" "%]+' '{print $4}'`
#cpu_idle=`top -n 1 | grep 'Cpu(s)' | awk -F'[" "%]+' '{print $8}'`
 
# 默认bash shell不能直接运算小数点，所以需要借助bc
# bc命令是一种支持任意精度的交互执行的计算器语言。
# 常见用法 echo "1.23*5" | bc 
 
#cpu_sum=$(echo "$cpu_us+$cpu_sy"|bc)
#echo "CPU_SUM: $cpu_sum%"
#echo "CPU_Idle: ${cpu_idle}%"
 
#超过阀值即发送邮件
#if [ $cpu_sum -ge 90 ];then
#        echo "CPU utilization $cpu_sum" | mail -s "cpu status warning." heyw@biyouxinli.com
#fi


#获取cpu使用率
cpuUsage=`top -n 1 | awk -F ‘[ %]+‘ ‘NR==3 {print $2}‘`
#获取磁盘使用率
data_name="/dev/vda1"
diskUsage=`df -h | grep $data_name | awk -F ‘[ %]+‘ ‘{print $5}‘`
logFile=/tmp/cpu.log
#获取内存情况
mem_total=`free -m | awk -F ‘[ :]+‘ ‘NR==2{print $2}‘`
mem_used=`free -m | awk -F ‘[ :]+‘ ‘NR==3{print $3}‘`
#统计内存使用率
mem_used_persent=`awk ‘BEGIN{printf "%.0f\n",(‘$mem_used‘/‘$mem_total‘)*100}‘`
#获取报警时间
now_time=`date ‘+%F %T‘`
function send_mail(){
        mail -s "监控报警" 1135960569@qq.com < /tmp/jiankong.log
}
function check(){
        if [[ "$cpuUsage" > 80 ]] || [[ "$diskUsage" > 80 ]] || [[ "$mem_used_persent" > 80 ]];then
                echo "报警时间：${now_time}" > $logFile
                echo "CPU使用率：${cpuUsage}% --> 磁盘使用率：${diskUsage}% --> 内存使用率：${mem_used_persent}%" >> $logFile
                send_mail
        fi
}
function main(){
        check
}
main

