#!/bin/sh

sudo dpkg --list|grep -i jdk
sudo apt-get purge openjdk*
sudo apt-get purge icedtea-* openjdk-*
sudo rm -rf /usr/lib/jvm/jdk*
sudo dpkg --list|grep -i jdk
