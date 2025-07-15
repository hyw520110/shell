#!/bin/bash

# === 🔐 默认配置 ===
DEFAULT_COUNTRY="CN"
DEFAULT_STATE="zhejiang"
DEFAULT_CITY="hangzhou"
DEFAULT_ORG="bot"
DEFAULT_OU="IT"
DEFAULT_DOMAIN="localhost"
DEFAULT_DAYS=365
DEFAULT_KEY_SIZE=2048
DEFAULT_PREFIX="server"

# === 🧾 变量初始化（由用户输入或参数决定）===
KEY_FILE=""
CSR_FILE=""
CRT_FILE=""
PFX_FILE=""
PREFIX=""

# 获取脚本名称，用于输出提示信息
SCRIPT_NAME=$(basename "$0")

# === 📌 函数定义 ===

# 显示本地证书信息
function show_local_cert_info() {
    local cert_file="$1"
    if [[ ! -f "$cert_file" ]]; then
        echo "❌ 错误：文件 '$cert_file' 不存在。"
        exit 1
    fi
    openssl x509 -in "$cert_file" -text -noout
}

# 获取远程 HTTPS 网站证书信息
function show_remote_cert_info() {
    local url="$1"
    local host port
    if [[ "$url" =~ ^https://([^:/]+)(:([0-9]+))?$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
        port=${port:-443}
    else
        echo "❌ 错误：无效的 HTTPS 链接格式。示例：https://example.com"
        exit 1
    fi

    echo "🔍 正在连接 $host:$port 获取证书..."
    echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null | openssl x509 -noout -dates -subject -issuer -ext subjectAltName
}

# 解析命令行参数
function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                shift
                PREFIX="$1"
                ;;
            --key)
                shift
                KEY_FILE="$1"
                ;;
            --csr)
                shift
                CSR_FILE="$1"
                ;;
            --crt)
                shift
                CRT_FILE="$1"
                ;;
            --pfx)
                shift
                PFX_FILE="$1"
                ;;
            *)
                OTHER_ARGS+=("$1")
                ;;
        esac
        shift
    done

    # 如果指定了 prefix，但没有显式指定文件名，则使用 prefix 生成默认文件名
    if [[ -n "$PREFIX" && -z "$KEY_FILE" ]]; then KEY_FILE="${PREFIX}.key"; fi
    if [[ -n "$PREFIX" && -z "$CSR_FILE" ]]; then CSR_FILE="${PREFIX}.csr"; fi
    if [[ -n "$PREFIX" && -z "$CRT_FILE" ]]; then CRT_FILE="${PREFIX}.crt"; fi
    if [[ -n "$PREFIX" && -z "$PFX_FILE" ]]; then PFX_FILE="${PREFIX}.pfx"; fi

    # 如果未指定 prefix 且未指定所有文件名，则使用默认 prefix
    if [[ -z "$KEY_FILE" && -z "$CSR_FILE" && -z "$CRT_FILE" && -z "$PFX_FILE" ]]; then
        KEY_FILE="${DEFAULT_PREFIX}.key"
        CSR_FILE="${DEFAULT_PREFIX}.csr"
        CRT_FILE="${DEFAULT_PREFIX}.crt"
        PFX_FILE="${DEFAULT_PREFIX}.pfx"
    fi
}

# 生成 RSA 私钥
function generate_rsa_key() {
    local key_size="$1"
    openssl genrsa  -out "$KEY_FILE" "$key_size"
}

# 生成 ECC 私钥
function generate_ecc_key() {
    local curve="$1"
    openssl ecparam -name "$curve" -genkey -noout -out "$KEY_FILE"
}
# 生成 CSR（兼容低版本 OpenSSL）
function generate_csr() {
    local domain="$1"
    local country="$2"
    local state="$3"
    local city="$4"
    local org="$5"
    local ou="$6"
    local key_type="$7"

    local subj="/C=$country/ST=$state/L=$city/O=$org/OU=$ou/CN=$domain"
    
    # 创建临时配置文件
    local tmpconf=$(mktemp)
    cat > "$tmpconf" <<EOL
[ req ]
default_bits        = 2048
prompt              = no
default_md          = sha256
distinguished_name  = dn
req_extensions      = v3_req

[ dn ]
C  = $country
ST = $state
L  = $city
O  = $org
OU = $ou
CN = $domain

[ v3_req ]
subjectAltName = DNS:$domain
EOL

    openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" -subj "$subj" -config "$tmpconf"
    rm -f "$tmpconf"
}
# 生成自签名证书
function generate_self_signed_cert() {
    local days="$1"
    openssl req -x509 -days "$days" -key "$KEY_FILE" -out "$CRT_FILE" -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=$DOMAIN"
    if [[ $? -ne 0 || ! -f "$CRT_FILE" ]]; then
	    echo "❌ 错误：自签名证书生成失败。"
	    exit 1
	fi
}
# 生成 PKCS#12 文件（pfx/p12）
function generate_pkcs12() {
    openssl pkcs12 -export -out "$PFX_FILE" -inkey "$KEY_FILE" -in "$CRT_FILE" -certfile "$CRT_FILE"
}

# 打印证书基本信息
function print_cert_summary() {
    echo -e "\n📄 证书信息预览:"
    openssl x509 -in "$CRT_FILE" -text -noout | grep -A 3 "Subject:" | head -n 3
    openssl x509 -in "$CRT_FILE" -text -noout | grep -A 3 "Validity"
}

# 常用命令提示
function print_common_commands() {
    echo -e "\n📌 常用证书查看命令："
    echo "1. 查看证书详细内容: openssl x509 -in $CRT_FILE -text -noout"
    echo "2. 查看私钥内容: openssl rsa -in $KEY_FILE -text -noout (RSA) / openssl ec -in $KEY_FILE -text -noout (ECC)"
    echo "3. 查看CSR内容: openssl req -in $CSR_FILE -text -noout"
    echo "4. 验证证书是否匹配私钥: openssl x509 -noout -modulus -in $CRT_FILE | openssl md5 && openssl pkey -noout -modulus -in $KEY_FILE | openssl md5"
    # 导入到 Java 运行时的信任库 (cacerts) 中
    # openssl s_client -connect localhost:8095 -showcerts </dev/null 2>/dev/null | openssl x509 -outform PEM > server_chain.pem
    # sudo su - && keytool -importcert -trustcacerts -file server_chain.pem -alias funasr_server_chain -keystore /opt/jdk-11.0.1.jdk/Contents/Home/lib/security/cacerts -storepass 'changeit'
}

# 添加信任命令提示
function print_trust_commands() {
    echo -e "\n🔒 如需将证书加入系统信任，请按平台执行以下命令："
    echo "- Linux (Ubuntu/Debian): sudo cp $CRT_FILE /usr/local/share/ca-certificates/ && sudo update-ca-certificates"
    echo "- macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CRT_FILE"
    echo "- Windows (PowerShell管理员权限): certutil -addstore -f \"Root\" $CRT_FILE"
}

# 主要交互流程：生成证书
function interactive_generate_cert() {

    # 用户选择密钥类型
    echo "请选择证书类型："
    echo "1) RSA（传统算法）"
    echo "2) ECC（椭圆曲线，更安全高效）"
    read -p "请输入选项 [1/2]: " key_type_choice
    case "$key_type_choice" in
        1)
            KEY_TYPE="rsa"
            #read -p "请输入 RSA 密钥位数 [$DEFAULT_KEY_SIZE] (支持 2048/3072/4096): " KEY_SIZE
            KEY_SIZE=${KEY_SIZE:-$DEFAULT_KEY_SIZE}
            ;;
        2)
            KEY_TYPE="ecc"
            echo "请选择 ECC 曲线："
            echo "1) secp256r1 (P-256)"
            echo "2) secp384r1 (P-384)"
            echo "3) secp521r1 (P-521)"
            read -p "请输入选项 [1/2/3]: " ecc_curve_choice
            case "$ecc_curve_choice" in
                1) ECC_CURVE="secp256r1" ;;
                2) ECC_CURVE="secp384r1" ;;
                3) ECC_CURVE="secp521r1" ;;
                *) echo "❌ 输入错误，默认使用 secp256r1"; ECC_CURVE="secp256r1" ;;
            esac
            ;;
        *)
            echo "❌ 输入错误，默认使用 RSA 2048"
            KEY_TYPE="rsa"
            KEY_SIZE=${DEFAULT_KEY_SIZE}
            ;;
    esac

    # 用户输入域名等信息
    read -p "请输入域名或IP地址 [$DEFAULT_DOMAIN]: " INPUT_DOMAIN
    DOMAIN=${INPUT_DOMAIN:-$DEFAULT_DOMAIN}

    COUNTRY=${COUNTRY:-$DEFAULT_COUNTRY}
    STATE=${STATE:-$DEFAULT_STATE}
    CITY=${CITY:-$DEFAULT_CITY}
    ORG=${ORG:-$DEFAULT_ORG}
    OU=${OU:-$DEFAULT_OU}
    DAYS=${DAYS:-$DEFAULT_DAYS}

    # 生成私钥
    if [[ "$KEY_TYPE" == "rsa" ]]; then
        echo "🧱 正在生成 $KEY_SIZE 位 RSA 私钥..."
        generate_rsa_key "$KEY_SIZE"
    else
        echo "🧱 正在生成 ECC 曲线 $ECC_CURVE 私钥..."
        generate_ecc_key "$ECC_CURVE"
    fi

    echo "✅ 已生成私钥: $KEY_FILE"

    # 生成 CSR
    generate_csr "$DOMAIN" "$COUNTRY" "$STATE" "$CITY" "$ORG" "$OU" "$KEY_TYPE"
    echo "✅ 已生成证书请求: $CSR_FILE"

    # 生成自签名证书
    generate_self_signed_cert "$DAYS"
    echo "✅ 已生成自签名证书: $CRT_FILE"

    # 可选生成 PFX
    if [[ -n "$PFX_FILE" ]]; then
        generate_pkcs12
        echo "✅ 已生成PKCS#12证书: $PFX_FILE"
    else
        read -p "是否生成 PKCS#12 格式 (.pfx/.p12)? [y/N]: " gen_pfx
        if [[ "$gen_pfx" =~ ^[Yy]$ ]]; then
            PFX_FILE="${DOMAIN//./_}.pfx"
            generate_pkcs12
            echo "✅ 已生成PKCS#12证书: $PFX_FILE"
        fi
    fi

    # 输出证书摘要
    print_cert_summary

    # 输出常用命令
    print_common_commands

    # 输出添加信任命令
    print_trust_commands

    # 安全提示
    echo -e "\n⚠️ 注意事项:"
    echo -e "- 自签名证书不被浏览器信任，仅用于开发/测试环境！"
    echo -e "- 生产环境请使用 Let's Encrypt 或 CA 签发的证书。"
    echo -e "- 私钥 ($KEY_FILE) 必须严格保密！"

    # 使用示例
    echo -e "\n📝 使用示例(Nginx配置):"
    echo -e "ssl_certificate     /path/to/$CRT_FILE;"
    echo -e "ssl_certificate_key /path/to/$KEY_FILE;"

}

# === 🚀 主程序逻辑 ===

OTHER_ARGS=()
parse_args "$@"

if [[ ${#OTHER_ARGS[@]} -ge 1 ]]; then
    first_arg="${OTHER_ARGS[0]}"
    if [[ "$first_arg" =~ ^https:// ]]; then
        show_remote_cert_info "$first_arg"
    elif [[ -f "$first_arg" ]]; then
        show_local_cert_info "$first_arg"
    else
        echo "❌ 参数错误：'$first_arg' 不是有效的 HTTPS 链接也不是存在的证书文件。"
        exit 1
    fi
else
    echo "📘 欢迎使用证书工具"
    echo "💡 提示：你可以传入一个 HTTPS 链接或本地证书文件来查看证书信息，例如："
    echo "   ./${SCRIPT_NAME} https://example.com"
    echo "   ./${SCRIPT_NAME} server.crt"
    echo ""
    interactive_generate_cert
fi