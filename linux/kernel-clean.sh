#!/bin/sh
#
# 清理ubuntu的老内核
#sudo aptitude purge ~ilinux-image-.*\(\!`uname -r`\)
CURRENT="`uname -r | awk -F"-" '{print $1"-"$2}'`"
HEADERS=""
IMAGES=""
for HEADER in `dpkg --get-selections | grep ^linux-headers | \
grep -vE "(generic|386|virtual)" | awk '{gsub(/linux-headers-/,"",$1);print $1}'`
do
    if [[ "$CURRENT" < "$HEADER" ]]
    then
        echo "正在运行的内核不是最新的。 $CURRENT < $HEADER"
        echo "Running kernel is not the newest. $CURRENT < $HEADER"
        exit 1
    else
        [[ "$CURRENT" != "$HEADER" ]] && {
            HEADERS="${HEADERS} linux-headers-${HEADER}"
            IMAGE="`dpkg --get-selections | grep ^linux-image | \
                grep "${HEADER}" | awk '{print $1}'`"
            IMAGES="${IMAGES} $IMAGE"
        }
    fi
done
if [[ x"$HEADERS" == x"" ]]
then
    echo "没有要清理的老内核."
    echo "No old kernel need to clean."
    exit 0
fi
CMD="sudo apt-get purge $HEADERS $IMAGES"
echo "$CMD"
if [ "$1" == "-e" ]
then
    sh -c "$CMD"
else
    echo "请确定以上命令是否正确，然后输入 $0 -e 来执行以上命令。"
    echo "Be sure this command is right, then type $0 -e to execute."
fi
