#!/bin/bash

syncSystemTime() {
    echo "*/5 * * * * /sbin/ntpdate cn.pool.ntp.org >/dev/null 2>&1" >> /var/spool/cron/root
}