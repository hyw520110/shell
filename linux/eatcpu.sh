#!/bin/bash
#random range
min=10
max=600
#log file
log_file=/tmp/cpu.log
pid_file=/tmp/cpu_pid.log

function log(){
 echo "$(date "+%Y-%m-%d %H:%M:%S"):$1" >> $log_file
}

if [ $# != 1 ] ; then 
  echo "USAGE: $0 <CPUs>"
  echo "cpu physical num:`cat /proc/cpuinfo| grep "physical id"| sort| uniq| wc -l`"
  echo "cpu cores num:`cat /proc/cpuinfo| grep "cpu cores"| uniq`"
  exit 1; 
fi

log "`top -b -n 1|grep Cpu`"
[ -s $pid_file ] && log "kill `cat $pid_file`" && cat $pid_file|xargs kill -9  && echo "" >$pid_file

for i in `seq $1` 
do
  echo -ne "  
i=0;  
while true 
do 
i=i+1;  
done" | /bin/sh & 
  pid_array[$i]=$! ; 
done


for i in "${pid_array[@]}"; do
  log "pid: $i" 
  echo "$i" >>$pid_file
done

log "`top -b -n 1|grep Cpu`"
time=$(./random.sh $min $max)
log "sleep $time"
sleep $time

for i in "${pid_array[@]}"; do
  log "kill $i" && kill $i;
  log "`top -b -n 1|grep Cpu`"
done 

