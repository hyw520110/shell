#!/bin/bash

# 检查是否已经安装了 git 和 ssh-keygen
for cmd in git ssh-keygen; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "$cmd 未安装。请先安装 $cmd。"
        exit 1
    fi
done

# 显示现有的 SSH 密钥文件
echo "现有的 SSH 密钥文件:"
find ~/.ssh -name "id_rsa*" -type f -print 2>/dev/null

# 显示现有的 Git 配置
echo "现有的 Git 配置:"
git config --list 2>/dev/null | grep -E 'user.name|user.email' || echo "无 Git 用户信息配置"

# 获取用户输入的邮箱地址
read -p "请输入用于新 SSH 密钥的邮箱地址: " email
if [ -z "$email" ]; then
    # 尝试从 git 配置中获取邮箱
    email=$(git config user.email 2>/dev/null)
    if [ -z "$email" ]; then
        email=$(git config --global user.email 2>/dev/null)
    fi
    if [ -z "$email" ]; then
        read -p "未检测到 git 配置邮箱，请输入邮箱地址: " email
        if [ -z "$email" ]; then
            echo "邮箱地址不能为空。请重新运行脚本并输入有效的邮箱地址。"
            exit 1
        fi
    else
        echo "已自动检测到 git 配置邮箱: $email"
    fi
fi

# 提取用户名作为默认值（邮箱@前的部分）
default_username=$(echo "$email" | cut -d '@' -f1)

# 如果当前不是 Git 仓库，则使用全局配置
in_git_repo="true"
if [ ! -d .git ]; then
    in_git_repo="false"
    echo "不在 Git 仓库中。将配置为全局设置。"
fi

# 获取用户名配置
current_name=""
if [ "$in_git_repo" = "true" ]; then
    current_name=$(git config user.name 2>/dev/null)
else
    current_name=$(git config --global user.name 2>/dev/null)
fi

if [ -z "$current_name" ]; then
    read -p "请输入 Git 用户名 (默认为 $default_username): " username
    username=${username:-$default_username}
else
    echo "已配置用户名: $current_name"
    read -p "是否更改用户名？(y/N): " change_user
    if [[ "$change_user" =~ ^[Yy]$ ]]; then
        read -p "请输入新的 Git 用户名 (默认为 $default_username): " username
        username=${username:-$default_username}
    else
        username="$current_name"
    fi
fi

# 定义密钥文件路径
key_file_base="~/.ssh/id_rsa_${email//@/_at_}"
key_file_base=$(eval echo "$key_file_base")
key_file="$key_file_base"
pub_key_file="$key_file.pub"

# 检查默认密钥是否存在该邮箱
if [ -f ~/.ssh/id_rsa.pub ] && grep -q "$email" ~/.ssh/id_rsa.pub; then
    echo "默认密钥文件中已存在该邮箱的公钥。"
    exit 0
fi

# 生成新的 SSH 密钥
if [ ! -f "$pub_key_file" ]; then
    echo "正在生成新的 SSH 密钥..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t rsa -C "$email" -f "$key_file" -q -N ""
    chmod 600 "$key_file"
    chmod 644 "$pub_key_file"
    echo "新的 SSH 密钥已生成于 $key_file"
else
    echo "SSH 密钥已存在于 $key_file"
    chmod 600 "$key_file"
    chmod 644 "$pub_key_file"
fi

# 设置 Git 用户名和邮箱
set_git_config() {
    local scope="$1"
    git config ${scope:+--$scope} user.name "$username"
    git config ${scope:+--$scope} user.email "$email"
    echo "Git 配置已更新：用户名=$username，邮箱=$email"
}

if [ "$in_git_repo" = "true" ]; then
    read -p "您希望将其配置为局部设置还是全局设置？(局部/全局) [默认: 全局]: " config_type
    config_type=${config_type:-全局}
    if [ "$config_type" = "局部" ]; then
        set_git_config ""
    elif [ "$config_type" = "全局" ]; then
        set_git_config "global"
    else
        echo "无效选项，默认设置为全局。"
        set_git_config "global"
    fi
else
    set_git_config "global"
fi

# 更新 SSH 配置文件
ssh_config_file=~/.ssh/config
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch "$ssh_config_file" # 优化点：先touch确保文件存在
chmod 600 "$ssh_config_file" # 优化点：再设置权限

hostname=github.com
host_alias=github.com
host_config_exists=$(awk '/^Host[ 	]+github.com$/ {print NR}' "$ssh_config_file")

# 需要的配置内容
required_config="Host github.com\n    HostName github.com\n    User git\n    IdentityFile $key_file\n"

if [ -z "$host_config_exists" ]; then
    # 没有 Host github.com，直接追加
    echo "正在添加 SSH 配置: Host github.com"
    printf "%b\n" "$required_config" >> "$ssh_config_file"
    echo "SSH 配置信息已添加"
else
    # Host github.com 存在，检查并修正配置
    start_line=$(awk '/^Host[ 	]+github.com$/ {print NR}' "$ssh_config_file")
    end_line=$(awk "NR>$start_line && /^Host / {print NR; exit}" "$ssh_config_file")
    if [ -z "$end_line" ]; then
        end_line=$(wc -l < "$ssh_config_file")
    else
        end_line=$((end_line-1))
    fi
    # 取出 Host github.com 配置块
    config_block=$(sed -n "${start_line},${end_line}p" "$ssh_config_file")
    need_update=0
    echo "$config_block" | grep -q "HostName github.com" || need_update=1
    echo "$config_block" | grep -q "User git" || need_update=1
    echo "$config_block" | grep -q "IdentityFile $key_file" || need_update=1
    if [ $need_update -eq 1 ]; then
        echo "检测到 Host github.com 配置不正确，正在自动修正..."
        # sed -i 的兼容性在macOS和GNU/Linux上不同，这里的-i.bak适用于macOS/BSD
        # 建议在跨平台使用时增加判断
        sed -i.bak "/^Host[ 	]*github.com$/,/^Host /{ /^Host[ 	]*github.com$/b; /^Host /b; d }" "$ssh_config_file"
        # 在文件末尾追加正确配置
        printf "%b\n" "$required_config" >> "$ssh_config_file"
        echo "Host github.com 配置已修正"
    else
        echo "Host github.com 配置已存在且正确"
    fi
fi

# 输出最终提示
echo ""
echo "✅ 设置已完成。您可以使用新的 SSH 密钥进行身份验证。"
echo "SSH 密钥位置: $key_file"
echo "公钥内容如下（可用于 GitHub/Gitee 等平台添加）："
cat "$pub_key_file"
echo "github配置：settings中找到ssh and gpg keys添加ssh key添加以上公钥内容"
echo "测试连接: ssh -T git@github.com"

# === 常用 Git 全局配置 ===
echo ""
echo "正在设置常用 Git 全局配置..."

# 1. 分支默认名为 main
if git config --global init.defaultBranch | grep -q main; then
  echo "分支默认名已为 main"
else
  git config --global init.defaultBranch main
  echo "已设置新仓库默认分支名为 main (git config --global init.defaultBranch main)"
fi
# 编辑器
git config --global core.editor "vim"

# 2. 颜色高亮
if git config --global color.ui | grep -q auto; then :; else
git config --global color.ui auto
echo "已开启 git 颜色高亮 (git config --global color.ui auto)"
fi

# 3. 常用别名
alias=(
  "st=status"
  "ci=commit"
  "co=checkout"
  "br=branch"
  "last=log -1 HEAD"
  "lg=log --oneline --graph --all --decorate"
)
for a in "${aliases[@]}"; do
  k="${a%%=*} "
  v="${a#*=}"
  git config --global alias.$k "$v"
done
echo "已设置常用 git 命令别名 (st, ci, co, br, last, lg)"

# 4. 忽略文件权限变更
if git config --global core.fileMode | grep -q false; then :; else
git config --global core.fileMode false
echo "已设置忽略文件权限变更 (git config --global core.fileMode false)"
fi

# 5. 处理换行符（自动判断平台）
if [[ "$(uname)" == "Darwin" || "$(uname)" == "Linux" ]]; then
  git config --global core.autocrlf input
  echo "已设置 core.autocrlf=input (适合 macOS/Linux)"
else
  git config --global core.autocrlf true
  echo "已设置 core.autocrlf=true (适合 Windows)"
fi

git config --global core.safecrlf warn

# 6. 记住凭证（优先 macOS 钥匙串，否则用 cache）
if [[ "$(uname)" == "Darwin" ]]; then
  git config --global credential.helper osxkeychain
  echo "已设置 credential.helper=osxkeychain (macOS)"
else
  git config --global credential.helper cache
  echo "已设置 credential.helper=cache (其他平台)"
fi

# 7. 显示中文路径
if git config --global core.quotepath | grep -q false; then :; else
git config --global core.quotepath false
echo "已设置 core.quotepath=false (显示中文路径)"
fi
# TODO 判断是否安装beyond compare，如安装没做软链接就做软链接，再更新git配置
# 8. 合并工具（优先 beyond compare，其次 code，否则 vimdiff）
if command -v bcompare >/dev/null 2>&1; then
  git config --global merge.tool bc
  git config --global mergetool.bc.cmd 'bcompare "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'
  git config --global mergetool.bc.trustExitCode true
  echo "已设置合并工具为 Beyond Compare (bcompare)"
elif command -v bcomp >/dev/null 2>&1; then
  # sudo ln -s /Applications/Beyond\ Compare.app/Contents/MacOS/bcomp /usr/local/bin/bcomp	
git config --global merge.tool bc
  git config --global mergetool.bc.cmd 'bcomp "$LOCAL" "$REMOTE" "$BASE" "$MERGED"'
  git config --global mergetool.bc.trustExitCode true
  echo "已设置合并工具为 Beyond Compare (bcomp)"
elif command -v code >/dev/null 2>&1; then
  git config --global merge.tool code
  echo "已设置合并工具为 VSCode (code)"
else
  git config --global merge.tool vimdiff
  echo "已设置合并工具为 vimdiff"
fi

echo ""
echo "✅ 常用 Git 全局配置已完成！"
echo ""

# === 自动测试 SSH 连接 github.com ===
echo "正在自动测试 SSH 连接 github.com..."
ssh -T git@github.com 2>&1 | tee /tmp/git_ssh_test.log | grep -q 'successfully authenticated'
if [ $? -eq 0 ]; then
  echo ""
  echo "✅ SSH 连接 GitHub 成功！你可以正常使用 git push/pull/clone 等操作。"
else
  echo ""
  echo "❌ SSH 连接 GitHub 失败！请按如下步骤操作："
  echo ""
  echo "公钥内容如下（可用于 GitHub/Gitee 等平台添加）："
  echo ""
  cat "$pub_key_file"
  echo ""
  echo "github配置：settings中找到ssh and gpg keys添加ssh key添加以上公钥内容"
  echo ""
  echo "测试连接: ssh -T git@github.com"
  echo ""
  echo "如仍有问题，请检查 ~/.ssh/config 配置或联系管理员。"
fi

# === 自动检测并启动 ssh-agent，并添加私钥 ===
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval "$(ssh-agent -s)"
    ssh-add "$key_file"
fi

echo "SSH agent 已启动并添加了密钥。"
