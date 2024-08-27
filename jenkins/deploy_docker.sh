#! /bin/sh
hrbor_url=$1
project=$2
projectName=$3
tag=$4
dockerRun=$5

echo "hrbor_url=$hrbor_url"
echo "dockerRun=$dockerRun"

projectUrl=$hrbor_url/$project/$projectName

imageName=$projectUrl:$tag

#查询容器是否存在，存在则删除
containerId=`docker ps -a | grep -w ${projectName} | awk '{print $1}'`
if [ "$containerId" !=  "" ] ; then
    #停掉容器
    docker kill $projectName

    #删除容器
    docker rm $projectName

	echo "成功删除容器"
fi

#查询镜像是否存在，存在则删除
imageId=`docker images | grep -w ${projectUrl}  | awk '{print $3}'`

if [ "$imageId" !=  "" ] ; then

    #删除镜像
    docker rmi -f $imageId

	echo "成功删除镜像"
fi
echo "地址 $harbor_url"
# 登录Harbor
docker login --username=admin --password=Lianxin@2021 $hrbor_url
# 下载镜像
docker pull $imageName

imageId=`docker images | grep -w $projectUrl  | awk '{print $3}'`
echo "镜像id: $imageId"

echo "$dockerRunSh $imageId"
# 启动容器
$dockerRun  $imageId

echo "容器启动成功"
