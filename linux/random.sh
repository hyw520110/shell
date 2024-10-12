#!/bin/bash
[ $# != 2 ] && echo "useage:$0 min max"
function rand() {
  min=$1
  max=$(($2-$min+1))
  num=$(cat /dev/urandom | head -n 10 | cksum | awk -F ' ' '{print $1}')
  echo $(($num%$max+$min))
}
  
rnd=$(rand $1 $2)
echo $rnd
  
