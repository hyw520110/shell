#!/bin/bash
# gitlab统计脚本，参数1url链接；参数2token,必须要有user、project等权限
# TODO 获取统计仓库提交
# https://www.cnblogs.com/sanzangtdashi/p/11807106.html
# https://blog.csdn.net/hello_1995/article/details/127489666#t7
echo "get cuurnt path"
basePath=$(cd $(dirname $0);pwd)
echo $basePath
cd $basePath
 
# 获取参数
GitLab_URL=${1:-"http://dev1.shangjinuu.com/"}
TOKEN=$2
echo $GitLab_URL 
echo $TOKEN
 
# 初始化日志文件
if [ ! -d "$basePath/log" ]; then
   mkdir -p $basePath/log
else
   rm -rf $basePath/log/*
fi
# ------------------------------------------------定义记录日志函数------------------------------------------------
function logger(){
  printf "%s\n" "$*" >> $basePath/log/StatisticsNum.log
}
 
# ------------------文本转化格式化HTML函数(参数：name_with_namespace、description、branch、http_url_to_repo 结果文件路径)------------------
function HTMLFormat(){
  echo "<tr>" >> $7
  echo "<th align="center">$1</th>" >> $7
  echo "<th align="center">$2</th>" >> $7
  echo "<th align="center">$3</th>" >> $7
  echo "<th align="center">$4</th>" >> $7
  echo "<th align="center">$5</th>" >> $7
  echo "<th align="center">$6</th>" >> $7
  echo "</tr>" >> $7
}

function mkdirs(){
	if [ ! -n "$1" ];then
		return
	fi
	if [ ! -d "$1" ]; then
       mkdir -p $1
    else
       rm -rf $1
    fi
}
 
# ------------------------------------------------定义获取信息函数/参数：TOKEN、GitLab库URL------------------------------------------------
function gitlabRepositry(){
    cd $basePath
	# 初始化相关路径
	mkdirs $basePath/report/*
	mkdirs $basePath/temp/*
    # 获取总页数
	total_pages=$( curl --head --header "PRIVATE-TOKEN:$2" "$1/api/v4/projects?per_page=50" | grep '^X-Total-Pages' | sed 's/X-Total-Pages: //g' | sed 's/\r//g' )
	[ ! -n "$total_pages" ] && echo "获取不到仓库数据，确认token是否正确匹配：$1 $2" && exit 0
	# 判断json格式化工具jq是否安装，未安装则安装
	[ `jq --version 2>/dev/null |grep jq-|grep -v grep |wc -l` -eq 0 ] && yum install -y jq
	
	echo "共计 $total_pages 页数据"
    # 遍历处理每页元数据
	for (( p=1; p<total_pages; p++ )) {
        echo "开始获取第 $p 页仓库元信息-----"
		curl --header "PRIVATE-TOKEN:$2" "$1/api/v4/projects?per_page=50&page=$p" | jq > $basePath/temp/gitlab_projects.json
		# 获取服务器上全部分支的相关信息元数据
		cat $basePath/temp/gitlab_projects.json | grep -w -B 1 -A 15 '"description"' > $basePath/temp/detailedInformation
		cat $basePath/temp/detailedInformation | grep -w '"id"' > $basePath/temp/PROJECT_ID
		cat $basePath/temp/detailedInformation | grep -w '"description"' > $basePath/temp/PROJECT_DESCRIPTION
		cat $basePath/temp/detailedInformation | grep -w '"name_with_namespace"' > $basePath/temp/PROJECT_NAME_WITH_NAMESPACE
		cat $basePath/temp/detailedInformation | grep -w '"created_at"' > $basePath/temp/PROJECT_CREATED_AT
		cat $basePath/temp/detailedInformation | grep -w '"default_branch"' > $basePath/temp/PROJECT_DEFAULT_BRANCH
		cat $basePath/temp/detailedInformation | grep -w '"http_url_to_repo"' > $basePath/temp/PROJECT_HTTP_URL_TO_REPO
		cat $basePath/temp/detailedInformation | grep -w '"last_activity_at"' > $basePath/temp/PROJECT_LAST_ACTIVITY_AT
		cd $basePath/temp
		paste PROJECT_ID PROJECT_DESCRIPTION PROJECT_NAME_WITH_NAMESPACE  PROJECT_CREATED_AT PROJECT_DEFAULT_BRANCH PROJECT_HTTP_URL_TO_REPO PROJECT_LAST_ACTIVITY_AT >> $basePath/temp/simplify_information
	}
# ------------------------------------------------遍历获取并格式化数据展示------------------------------------------------
# 添加列说明信息
HTMLFormat 项目群组和名称 项目描述 项目分支 URL路径 创建时间 最新变更时间 $basePath/report/unoccupied_projects_lists.html
HTMLFormat 项目群组和名称 项目描述 项目分支 URL路径 创建时间 最新变更时间 $basePath/report/GitLab_result.html
 
cat $basePath/temp/simplify_information | \
    while read LINE
    do
	    # 获取单项数据信息
        PROJECT_ID=$( echo $LINE | awk -F',' '{print $1}' | awk '{print $2}' )
	    PROJECT_DESCRIPTION=$( echo $LINE | awk -F'"description"' '{print $2}' | awk '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g' )
	    PROJECT_NAME_WITH_NAMESPACE=$( echo $LINE | awk -F'"name_with_namespace"' '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g' )
	    PROJECT_CREATED_AT=$( echo $LINE | awk -F'"created_at"' '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g' )
	    PROJECT_DEFAULT_BRANCH=$( echo $LINE | awk -F'"default_branch"' '{print $2}' | awk -F',' '{print $1}' | awk -F'"' '{print $2}' | sed 's/ //g' )
	    PROJECT_HTTP_URL_TO_REPO=$( echo $LINE | awk -F'"http_url_to_repo"' '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g' )
	    PROJECT_LAST_ACTIVITY_AT=$( echo $LINE | awk -F'"last_activity_at"' '{print $2}' | awk -F'"' '{print $2}' | sed 's/ //g' )
		if [ ! -n "$PROJECT_DESCRIPTION" ] ;then
	       PROJECT_DESCRIPTION="无描述信息"
	       echo "$PROJECT_HTTP_URL_TO_REPO 无描述信息!"
        fi
	    # 获取代码库分支元数据
		curl --header "PRIVATE-TOKEN:$2" "$1/api/v4/projects/$PROJECT_ID/repository/branches" | \
		    jq | \
			grep -w '"name"' | \
			awk -F'"' '{print $4}' > $basePath/temp/BRANCH_INFORMATION
		# 计算有效行数
		WCNUM=$( cat $basePath/temp/BRANCH_INFORMATION | wc -l ) 
		if [ $WCNUM -eq 0 ]; then
           echo "代码库 $PROJECT_HTTP_URL_TO_REPO 已空置！"
		   echo "$PROJECT_HTTP_URL_TO_REPO $PROJECT_DESCRIPTION $PROJECT_CREATED_AT $PROJECT_LAST_ACTIVITY_AT" >> $basePath/report/unoccupied_projects_lists
		   HTMLFormat $PROJECT_NAME_WITH_NAMESPACE $PROJECT_DESCRIPTION  NaN $PROJECT_HTTP_URL_TO_REPO $PROJECT_CREATED_AT $PROJECT_LAST_ACTIVITY_AT $basePath/report/unoccupied_projects_lists.html
        else
           # 遍历获取分支并进行信息合并
		   cat $basePath/temp/BRANCH_INFORMATION | \
		       while read BRANCH
               do
			       echo "$PROJECT_NAME_WITH_NAMESPACE $PROJECT_DESCRIPTION  $BRANCH $PROJECT_HTTP_URL_TO_REPO $PROJECT_CREATED_AT $PROJECT_LAST_ACTIVITY_AT" >> $basePath/temp/atom_Metadata
				   HTMLFormat $PROJECT_NAME_WITH_NAMESPACE $PROJECT_DESCRIPTION  $BRANCH $PROJECT_HTTP_URL_TO_REPO $PROJECT_CREATED_AT $PROJECT_LAST_ACTIVITY_AT $basePath/report/GitLab_result.html
			   done
        fi
        
    done
	logger "Run by user " $(id -un) "at " $(/bin/date)
	# 排序
	cat $basePath/temp/atom_Metadata | sort > $basePath/report/GitLab_result
 
}
 
# ------------------------------------------------调取函数生成分析数据------------------------------------------------
gitlabRepositry $GitLab_URL $TOKEN
 
# ------------------------------------------------有效项目报表格式化------------------------------------------------
# 获取有效项目报表全局统计信息
TOTAL_ROWS=$( cat $basePath/report/GitLab_result | wc -l )
TOTAL_PROJECTS=$( cat $basePath/temp/simplify_information | wc -l )
# 有效项目报表HTML格式化头
sed -i '1i <table border="1">' $basePath/report/GitLab_result.html
# 有效项目报表HTML格式化尾
echo "</table>" >> $basePath/report/GitLab_result.html
echo "<p>Statistics GitLab Server： 【$GitLab_URL】 <br /></p>" >> $basePath/report/GitLab_result.html
echo "<p>Statistics time： 【$(date +%Y-%m-%d/%H:%M)】 <br /></p>" >> $basePath/report/GitLab_result.html
echo "<p>Statistics total not unoccupied projects： 【$TOTAL_PROJECTS 】<br /></p>" >> $basePath/report/GitLab_result.html
echo "<p>Statistics total Rows 【$TOTAL_ROWS】<br /></p>" >> $basePath/report/GitLab_result.html
 
# ------------------------------------------------空置项目报表格式化------------------------------------------------
# 获取空置项目报表全局统计信息
TOTAL_ROWS=$( cat $basePath/report/unoccupied_projects_lists | wc -l )
# 空置项目报表HTML格式化头
sed -i '1i <table border="1">' $basePath/report/unoccupied_projects_lists.html
# 空置项目报表HTML格式化尾
echo "</table>" >> $basePath/report/unoccupied_projects_lists.html
echo "<p>Statistics GitLab Server： 【$GitLab_URL】 <br /></p>" >> $basePath/report/unoccupied_projects_lists.html
echo "<p>Statistics time： 【$(date +%Y-%m-%d/%H:%M)】 <br /></p>" >> $basePath/report/unoccupied_projects_lists.html
echo "<p>Statistics total Rows 【$TOTAL_ROWS】<br /></p>" >> $basePath/report/unoccupied_projects_lists.html
 
# ------------------------------------------------格式化展示数据------------------------------------------------
echo "-------------------------------- FORMAT SHOW  DATA --------------------------------"
column -t $basePath/report/GitLab_result
echo "-------------------------------- FORMAT SHOW  END ---------------------------------"
 
echo "-------------------------------- SHOW unoccupied branches DATA --------------------------------"
column -t $basePath/report/unoccupied_projects_lists
echo "-------------------------------- SHOW unoccupied branches END ---------------------------------"
 
# 压缩报告文件
zip -q -j -r $basePath/report/report-$(date "+%Y%m%d%H%M").zip $basePath/report
 
if [ $? -eq 0 ]; then
  echo "successed."
else
  echo "failed , please check this script ."
  exit 1
fi
