#!/bin/sh

for d in `ls /opt/webapps`
do
 /opt/skywalking-es7/cp-app-conf.sh $d
done

for f in `find /opt/skywalking-es7/ -name agent.config`
do
 echo $f 
sed -i "s#collector.backend_service=\${SW_AGENT_COLLECTOR_BACKEND_SERVICES:.*}#collector.backend_service=\${SW_AGENT_COLLECTOR_BACKEND_SERVICES:sk-server:11800}#g" $f
done
