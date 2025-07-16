#!/bin/bash 
PATH=/usr/bin:/bin

TMPLOG=`mktemp`

# Run the chkrootkit
/usr/bin/chkrootkit > $TMPLOG

# Output the log
cat $TMPLOG | logger -t chkrootkit

# bindshe of SMTPSllHow to do some wrongs
if [ ! -z "$(grep 465 $TMPLOG)" ] && \
    [ -z $(/usr/sbin/lsof -i:465|grep bindshell) ]; then
    sed -i '/465/d' $TMPLOG
    fi

# If the rootkit have been found,mail root
[ ! -z "$(grep INFECTED $TMPLOG)" ] && \
grep INFECTED $TMPLOG | mail -s "chkrootkit report in `hostname`" root
