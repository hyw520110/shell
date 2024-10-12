#!/bin/bash
[ -d /tmp/memory ] && umount /tmp/memory && rm -rf /tmp/memory
mkdir /tmp/memory
mount -t tmpfs -o size=1024M tmpfs /tmp/memory
dd if=/dev/zero of=/tmp/memory/block

time=$(./random.sh 300 600)

sleep $time
rm /tmp/memory/block
umount /tmp/memory
rmdir /tmp/memory
