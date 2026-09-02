#!/usr/bin/env bash
###############################################################################
# vLLM 一键安装配置脚本
# 支持: macOS / Linux (Ubuntu/Debian/CentOS)
# 用法: curl -fsSL <script_url> | bash
#    或: bash install_vllm.sh
###############################################################################
set -euo pipefail

# --------------------------- 颜色输出 ----------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; RESET='\033[0m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
yellow() { echo -e "${YELLOW}$*${NC}"; }

find_cmd() {
  local name="$1"
  local path
  if command -v "$name" &>/dev/null; then
    command -v "$name"
    return 0
  fi
  for path in \
    "/opt/homebrew/bin/${name}" \
    "/usr/local/bin/${name}" \
    "${HOME}/.local/bin/${name}" \
    "${HOME}/.pyenv/shims/${name}" \
    "${HOME}/.pyenv/bin/${name}"; do
    if [[ -x "$path" ]]; then
      echo "$path"
      return 0
    fi
  done
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/../common"
SHARED_MODEL_CATALOG_FILE="${COMMON_DIR}/models.catalog.tsv"
WHICHLLM_SCRIPT="${COMMON_DIR}/whichllm.sh"

# --------------------------- 变量默认值 --------------------------------------
# vLLM 版本: 留空 = 最新稳定版 (当前 PyPI 最新: 0.21.0)
# Apple Silicon (Mac Studio/M4 Max) 推荐: vllm-metal 最新版
VLLM_VERSION=""

# Python 版本: 留空 = 系统默认
# Apple Silicon 推荐: 3.12 (vllm-metal 必需)
# vLLM 支持 Python 3.10 - 3.14
PYTHON_VERSION=""

INSTALL_DIR="${HOME}/vllm"
VENV_DIR="${INSTALL_DIR}/venv"
MODEL_DIR="${INSTALL_DIR}/models"
CONFIG_FILE="${INSTALL_DIR}/vllm_config.env"
SERVICE_NAME="vllm"
DEFAULT_MODEL="qwen3.6-27b" # 主要编码场景的 128GB RAM 推荐首选 (Dense 27B, SWE-bench 77.2%)
DEFAULT_PORT=8001  # 避开 DS4 默认端口 8000
DEFAULT_SERVED_MODEL_NAME="studio-qwen-coder" # OpenAI API 对外稳定模型名，避免暴露本地模型路径
DEFAULT_TOOL_CALL_PARSER="qwen3_coder" # Qwen Code/OpenAI tools 兼容所需
DEFAULT_GPU_MEMORY_UTILIZATION=0.85 # 针对 128G 优化
DEFAULT_MAX_MODEL_LEN=65536         # 针对 M4 Max 128G + Qwen3.6-27B 实测可用的长上下文
DEFAULT_MAX_NUM_SEQS=3              # 降低并发以提高单人响应速度，足够支撑 1-3 人使用
DEFAULT_MAX_NUM_BATCHED_TOKENS=8192 # vllm-metal 64K 下 chunked prefill 的实测稳定值
DEFAULT_DISABLE_THINKING=true       # Qwen3.x chat template 默认关闭显式 thinking，避免 CLI 输出 <think> 内容并减少无效生成
DEFAULT_MAX_FILES_SOFT=65536        # macOS LaunchAgent / launchctl 文件描述符软限制
DEFAULT_MAX_FILES_HARD=200000       # macOS LaunchDaemon 文件描述符硬限制
DEFAULT_ENABLE_PREFIX_CACHING=true  # 复用重复前缀 KV cache；不改变输出质量，适合 CLI/工具调用反复携带相同上下文
AUTO_UPDATE=true         # 检测到新版本时默认自动更新
ENABLE_SPECULATIVE=false  # 投机解码开关
SPECULATIVE_CONFIG=""     # 投机解码 JSON 配置
LIST_MODELS=false
DOWNLOAD_ONLY_MODEL=""
MODEL_USER_SET=false
VERSION_PACKAGE_TARGET=""
LAST_VENV_BACKUP=""
LATEST_REMOTE_PACKAGE=""
LATEST_REMOTE_VERSION=""
UPDATE_PLATFORM_BLOCKED=false   # 本次"更新"因平台缺少 wheel 而不可安装时置 true
UPDATE_SKIP_CACHE_FILE="${INSTALL_DIR}/.update_skip.cache"

refresh_paths() {
  VENV_DIR="${INSTALL_DIR}/venv"
  MODEL_DIR="${INSTALL_DIR}/models"
  CONFIG_FILE="${INSTALL_DIR}/vllm_config.env"
}

# --------------------------- 引擎选择 ----------------------------------------
# 支持的引擎: vllm (标准), vllm-metal (Apple Silicon 默认), vllm-mlx (MLX 功能型备选)
# macOS Apple Silicon 默认: vllm-metal
# Linux / macOS Intel 默认: vllm
ENGINE=""  # 留空 = 自动选择
ENGINE_USER_SET=false

# --------------------------- 运行时变量初始化 --------------------------------
OS=""
ARCH=""
DISTRO=""
TOTAL_MEM_GB=0
HAS_GPU=false
GPU_TYPE="cpu"
GPU_NAME=""
GPU_MEMORY_GB=0
GPU_COUNT=1
CPU_NAME=""
CPU_CORES=0
CPU_PERF_CORES=0
RECOMMENDED_MODELS=""
PYTHON_CMD=""
PYTHON_PATH=""
PYTHON_VER=""
MEETS_MINIMUM=false

# --------------------------- 模型目录 ----------------------------------------
model_catalog() {
  [[ -f "${SHARED_MODEL_CATALOG_FILE}" ]] || {
    error "未找到共享模型目录: ${SHARED_MODEL_CATALOG_FILE}"
    exit 1
  }
  tail -n +2 "${SHARED_MODEL_CATALOG_FILE}" | tr '\t' '|'
}

WHICHLLM_PRIMARY_ALIAS=""
WHICHLLM_PRIMARY_CHOICE=""
WHICHLLM_CODING_ALIAS=""
WHICHLLM_REASONING_ALIAS=""
WHICHLLM_DOCS_ALIAS=""
WHICHLLM_LIGHT_ALIAS=""
WHICHLLM_DEEPSEEK_ALIAS=""
WHICHLLM_TOTAL_MEM_GB=""
WHICHLLM_AVAILABLE_MEM_GB=""
WHICHLLM_BUDGET_GB=""
WHICHLLM_GPU_TYPE=""
WHICHLLM_DS4_RUNNING=""

resolve_model_alias() {
  local name="$1"
  local row
  row=$(model_catalog | awk -F'|' -v key="$name" '$1 == key || $2 == key {print; exit}')
  if [[ -n "$row" ]]; then
    echo "$row" | awk -F'|' '{print $2}'
  else
    echo "$name"
  fi
}

model_default_max_len() {
  local name="$1"
  local row
  row=$(model_catalog | awk -F'|' -v key="$name" '$1 == key || $2 == key {print; exit}')
  [[ -n "$row" ]] && echo "$row" | awk -F'|' '{print $3}' || echo "$DEFAULT_MAX_MODEL_LEN"
}

model_use_case() {
  local name="$1"
  local row
  row=$(model_catalog | awk -F'|' -v key="$name" '$1 == key || $2 == key {print; exit}')
  [[ -n "$row" ]] && echo "$row" | awk -F'|' '{print $5}'
}

model_speculative_config() {
  local name="$1"
  local row
  row=$(model_catalog | awk -F'|' -v key="$name" '$1 == key || $2 == key {print; exit}')
  [[ -n "$row" ]] && echo "$row" | awk -F'|' '{print $7}'
}

model_local_dir() {
  local model_name="$1"
  model_name=$(resolve_model_alias "$model_name")
  printf '%s/%s\n' "$MODEL_DIR" "$(printf '%s' "$model_name" | tr '/' '_')"
}

model_dir_complete() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  if [[ -f "$dir/model.safetensors.index.json" ]]; then
    python3 - "$dir" <<'PY' 2>/dev/null
import json
import pathlib
import sys

model_dir = pathlib.Path(sys.argv[1])
index_file = model_dir / "model.safetensors.index.json"
data = json.loads(index_file.read_text())
files = sorted(set(data.get("weight_map", {}).values()))
if files and all((model_dir / name).is_file() for name in files):
    sys.exit(0)
sys.exit(1)
PY
    return $?
  fi
  find "$dir" -maxdepth 1 -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.gguf" \) -print -quit 2>/dev/null | grep -q .
}

model_runtime_ref() {
  local model_name="$1"
  local local_dir
  if [[ "$model_name" == /* || "$model_name" == ./* || "$model_name" == ../* ]]; then
    printf '%s\n' "$model_name"
    return 0
  fi
  model_name=$(resolve_model_alias "$model_name")
  local_dir=$(model_local_dir "$model_name")
  if model_dir_complete "$local_dir"; then
    printf '%s\n' "$local_dir"
  else
    printf '%s\n' "$model_name"
  fi
}

# ---- vllm-metal MLX 模型名称映射 ----
# 将标准 HuggingFace 模型名转换为 mlx-community 组织下的 MLX 格式模型名
# 规则: org/model-name -> mlx-community/model-name-4bit (或 -4bit)
# 对于已知模型使用精确映射, 未知模型使用通用规则
to_mlx_model_name() {
  local model="$1"

  # 如果已经是 MLX 格式, 直接返回
  if [[ "$model" == mlx-community/* ]]; then
    echo "$model"
    return
  fi

  # 如果是本地路径, 直接返回
  if [[ "$model" == /* || "$model" == ./* || "$model" == ../* ]]; then
    echo "$model"
    return
  fi

  # 已知模型的精确映射 (MLX 4bit 量化版)
  local -A mlx_map=(
    ["Qwen/Qwen3.6-27B"]="mlx-community/Qwen3.6-27B-4bit"
    ["Qwen/Qwen3.6-35B-A3B"]="mlx-community/Qwen3.6-35B-A3B-4bit"
    ["Qwen/Qwen3-Coder-30B-A3B-Instruct"]="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
    ["Qwen/Qwen2.5-Coder-32B-Instruct"]="mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"
    ["Qwen/Qwen3-30B-A3B"]="mlx-community/Qwen3-30B-A3B-4bit"
    ["Qwen/Qwen3-14B"]="mlx-community/Qwen3-14B-4bit"
    ["Qwen/Qwen3-8B"]="mlx-community/Qwen3-8B-4bit"
    ["Qwen/Qwen2.5-32B-Instruct"]="mlx-community/Qwen2.5-32B-Instruct-4bit"
    ["Qwen/Qwen2.5-14B-Instruct"]="mlx-community/Qwen2.5-14B-Instruct-4bit"
    ["Qwen/Qwen2.5-7B-Instruct"]="mlx-community/Qwen2.5-7B-Instruct-4bit"
    ["Qwen/Qwen2.5-72B-Instruct"]="mlx-community/Qwen2.5-72B-Instruct-4bit"
    ["deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"]="mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit"
    ["deepseek-ai/DeepSeek-R1-Distill-Qwen-14B"]="mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit"
    ["meta-llama/Llama-3.3-70B-Instruct"]="mlx-community/Llama-3.3-70B-Instruct-4bit"
    ["meta-llama/Llama-3.1-70B-Instruct"]="mlx-community/Llama-3.1-70B-Instruct-4bit"
    ["meta-llama/Llama-3.1-8B-Instruct"]="mlx-community/Llama-3.1-8B-Instruct-4bit"
    ["mistralai/Mistral-Small-24B-Instruct-2501"]="mlx-community/Mistral-Small-24B-Instruct-2501-4bit"
    ["google/gemma-3-27b-it"]="mlx-community/gemma-3-27b-it-4bit"
    ["microsoft/phi-4"]="mlx-community/phi-4-4bit"
    ["zai-org/GLM-4.6"]="mlx-community/GLM-4.6-4bit"
    ["01-ai/Yi-1.5-34B-Chat"]="mlx-community/Yi-1.5-34B-Chat-4bit"
  )

  if [[ -n "${mlx_map[$model]+x}" ]]; then
    echo "${mlx_map[$model]}"
    return
  fi

  # 通用规则: org/model-name -> mlx-community/model-name-4bit
  local base_name
  base_name=$(printf '%s' "$model" | sed 's|.*/||')
  echo "mlx-community/${base_name}-4bit"
}

list_model_catalog() {
  echo -e "${BOLD}vLLM 模型目录${RESET}"
  echo "别名 | HuggingFace 模型 | 建议上下文 | 估算内存 | 推荐用途 | 说明"
  echo "---- | ---------------- | -------- | -------- | -------- | ----"
  model_catalog | awk -F'|' '{printf "%s | %s | %s | ~%sGB | %s | %s\n", $1, $2, $3, $4, $5, $6}'
  echo ""
  echo "提示: DeepSeek-V4-Flash/Pro 是 vLLM 支持架构；DS4 使用的是专用 GGUF 路径，不等同于 vLLM 的 HF 模型加载。"
}

# --------------------------- 帮助信息 ----------------------------------------
usage() {
  cat <<EOF
用法: $0 [选项]

选项:
  -e, --engine ENGINE       推理引擎 (默认: macOS Apple Silicon=vllm-metal, 其他=vllm)
                            可选: vllm, vllm-mlx, vllm-metal
                            vllm:       标准 vLLM (Linux CUDA/ROCm, macOS MPS)
                            vllm-metal: 官方 Metal 插件, Mac Studio/Apple Silicon 首选
                            vllm-mlx:   MLX 后端, pip 安装, 多模态/Anthropic/MCP 功能型备选
  -v, --version VERSION     引擎版本 (默认: 最新稳定版)
                            vllm: PyPI 最新 (当前 0.21.0)
                            vllm-mlx: PyPI 最新 (当前 0.3.0)
                            vllm-metal: 通过安装脚本获取最新版
  -p, --python VERSION      Python 版本 (默认: 系统默认)
                            推荐: 3.12 (Apple Silicon/vllm-metal 必需)
                            注意: vllm-metal 要求 Python >= 3.12
  -i, --install-dir DIR     安装目录 (默认: ${INSTALL_DIR})
  -m, --model MODEL         默认加载模型 (默认: ${DEFAULT_MODEL})
  -o, --port PORT           API 端口 (默认: ${DEFAULT_PORT})
  -g, --gpu-util UTIL       GPU 内存利用率 0.1-1.0 (默认: ${DEFAULT_GPU_MEMORY_UTILIZATION})
  -l, --max-len LEN         最大序列长度 (默认: ${DEFAULT_MAX_MODEL_LEN})
      --list-models         列出内置模型目录和别名
      --download MODEL      只下载指定模型/别名到模型目录
  -u, --uninstall           卸载 vLLM
      --uninstall-engine ENGINE
                            非交互指定卸载目标: vllm, vllm-mlx, vllm-metal, all
                            也可使用: --uninstall -e vllm-metal --yes
  -n, --no-update           检测到新版本时不自动更新
      --auto                非交互模式: 自动选择推荐引擎/模型/下载，跳过所有提示
  -y, --yes                 自动确认下载等提示（仍需指定模型等参数）
  -h, --help                显示帮助

引擎对比 (macOS Apple Silicon):
  ┌─────────────┬──────────────────┬──────────────────┬──────────────────┐
  │             │ vllm             │ vllm-metal ★推荐 │ vllm-mlx         │
  ├─────────────┼──────────────────┼──────────────────┼──────────────────┤
  │ 安装方式    │ pip install      │ wheel/安装脚本   │ pip install      │
  │ Python 要求 │ >= 3.10          │ >= 3.12          │ >= 3.10          │
  │ 启动命令    │ vllm serve       │ vllm serve       │ vllm-mlx serve   │
  │ OpenAI API  │ ✓                │ ✓                │ ✓                │
  │ Anthropic   │ ✗                │ ✗                │ ✓                │
  │ 多模态      │ 部分             │ 主要文本         │ 文本+图+视频+音频│
  │ MCP 工具    │ ✗                │ ✗                │ ✓                │
  │ SSD 缓存    │ ✗                │ ✗                │ ✓                │
  │ 推测解码    │ ✓                │ ✓                │ ✓                │
  │ 维护者      │ vLLM 官方        │ vLLM 官方        │ waybarrios       │
  └─────────────┴──────────────────┴──────────────────┴──────────────────┘

Mac Studio M4 Max 128GB 推荐配置:
  引擎:        vllm-metal (官方 Metal 插件, vLLM 兼容路径)
  Python 版本: 3.12
  GPU 利用率:  0.85 (128GB 统一内存推荐)
  最大长度:    65536 (M4 Max 128G + Qwen3.6-27B 实测可用)
  并发序列:    4 (当前单人优先响应和稳定性；2-3 人使用可调到 6)
  前缀缓存:    true (复用重复系统提示/工具定义/项目上下文，不影响准确性)

示例:
  $0                                    # 默认安装 (macOS 自动选择 vllm-metal)
  $0 -e vllm-metal                      # 显式指定官方 Metal 插件
  $0 -e vllm-mlx                        # 需要多模态/Anthropic/MCP 时使用 vllm-mlx
  $0 -e vllm -p 3.12                    # 标准 vLLM + Python 3.12
  $0 -e vllm-metal -m qwen3.6-27b  # vllm-metal + 指定模型
  ${WHICHLLM_SCRIPT}                     # 如存在，可独立查看 whichllm 推荐
  $0 --list-models                       # 查看内置模型别名
  $0 --download deepseek-r1-distill-qwen-32b
  $0 --yes                               # 非交互运行，自动选择推荐模型并配置自启动
  $0 --no-update                        # 不自动更新
  $0 --uninstall                        # 交互选择卸载目标
  $0 --uninstall --uninstall-engine vllm-metal --yes
  $0 --uninstall -e vllm-mlx --yes
  VLLM_SKIP_SYSTEM_OPTIMIZE=1 $0 --yes   # 跳过 macOS maxfiles sudo 优化
EOF
  exit 0
}

# --------------------------- 参数解析 ----------------------------------------
UNINSTALL=false
UNINSTALL_TARGET=""
NO_UPDATE=false
ASSUME_YES=false
AUTO_MODE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -e|--engine) ENGINE="$2"; ENGINE_USER_SET=true; shift 2;;
    -v|--version) VLLM_VERSION="$2"; shift 2;;
    -p|--python) PYTHON_VERSION="$2"; shift 2;;
    -i|--install-dir) INSTALL_DIR="$2"; shift 2;;
    -m|--model) DEFAULT_MODEL="$2"; MODEL_USER_SET=true; shift 2;;
    -o|--port) DEFAULT_PORT="$2"; shift 2;;
    -g|--gpu-util) DEFAULT_GPU_MEMORY_UTILIZATION="$2"; shift 2;;
    -l|--max-len) DEFAULT_MAX_MODEL_LEN="$2"; shift 2;;
    --list-models) LIST_MODELS=true; shift;;
    --download) DOWNLOAD_ONLY_MODEL="$2"; shift 2;;
    -y|--yes) ASSUME_YES=true; shift;;
    --auto) ASSUME_YES=true; AUTO_MODE=true; shift;;
    -u|--uninstall) UNINSTALL=true; shift;;
    --uninstall-engine|--uninstall-target) UNINSTALL=true; UNINSTALL_TARGET="$2"; shift 2;;
    -n|--no-update) NO_UPDATE=true; AUTO_UPDATE=false; shift;;
    -h|--help) usage;;
    *) error "未知参数: $1"; usage;;
  esac
done
refresh_paths

# --------------------------- 引擎自动选择 ------------------------------------
resolve_engine() {
  local quiet="${1:-0}"
  if [[ -n "$ENGINE" ]]; then
    case "$ENGINE" in
      vllm|vllm-mlx|vllm-metal) ;;
      *) error "不支持的引擎: $ENGINE (可选: vllm, vllm-mlx, vllm-metal)"; exit 1;;
    esac
    return
  fi

  # 自动选择: macOS Apple Silicon → vllm-metal, 其他 → vllm
  if [[ "$(uname)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]; then
    ENGINE="vllm-metal"
    [[ "$quiet" == "1" ]] || info "检测到 Apple Silicon, 自动选择引擎: ${GREEN}vllm-metal${NC}"
  else
    ENGINE="vllm"
    [[ "$quiet" == "1" ]] || info "自动选择引擎: ${GREEN}vllm${NC}"
  fi
}

# --------------------------- 卸载逻辑 ----------------------------------------
validate_uninstall_target() {
  case "$1" in
    vllm|vllm-mlx|vllm-metal|all) return 0 ;;
    *) error "不支持的卸载目标: $1 (可选: vllm, vllm-mlx, vllm-metal, all)"; exit 1 ;;
  esac
}

config_engine() {
  [[ -f "${CONFIG_FILE}" ]] || return 0
  awk -F= '/^VLLM_ENGINE=/{gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "${CONFIG_FILE}" 2>/dev/null || true
}

venv_has_module() {
  local venv="$1" module="$2"
  [[ -x "${venv}/bin/python" ]] || return 1
  "${venv}/bin/python" - "$module" <<'PY' >/dev/null 2>&1
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec(sys.argv[1]) else 1)
PY
}

venv_has_distribution() {
  local venv="$1" dist="$2"
  [[ -x "${venv}/bin/python" ]] || return 1
  "${venv}/bin/python" - "$dist" <<'PY' >/dev/null 2>&1
import importlib.metadata as metadata
import sys
try:
    metadata.version(sys.argv[1])
except metadata.PackageNotFoundError:
    sys.exit(1)
sys.exit(0)
PY
}

detect_venv_engine_records() {
  local venv="$1" kind="$2"
  [[ -d "$venv" ]] || return 0
  [[ -x "${venv}/bin/python" ]] || return 0

  local has_mlx=false has_metal=false
  if venv_has_module "$venv" "vllm_mlx"; then
    has_mlx=true
    printf 'vllm-mlx\t%s\t%s\t%s\n' "$venv" "$kind" "检测到 Python 包 vllm_mlx"
  fi
  if venv_has_distribution "$venv" "vllm-metal"; then
    has_metal=true
    printf 'vllm-metal\t%s\t%s\t%s\n' "$venv" "$kind" "检测到 Python 包 vllm-metal"
  fi
  if [[ "$has_mlx" == "false" && "$has_metal" == "false" ]] && venv_has_module "$venv" "vllm"; then
    printf 'vllm\t%s\t%s\t%s\n' "$venv" "$kind" "检测到 Python 包 vllm"
  fi
}

detect_installed_engine_records() {
  local records="" seen="" line engine path kind note cfg_engine

  while IFS=$'\t' read -r engine path kind note; do
    [[ -n "${engine:-}" ]] || continue
    case "$seen" in *"|${engine}@${path}|"*) continue ;; esac
    seen="${seen}|${engine}@${path}|"
    records="${records}${engine}"$'\t'"${path}"$'\t'"${kind}"$'\t'"${note}"$'\n'
  done <<EOF
$(detect_venv_engine_records "${VENV_DIR}" "managed-venv")
EOF

  if [[ -d "$HOME/.venv-vllm-metal" && "$HOME/.venv-vllm-metal" != "${VENV_DIR}" ]]; then
    line="vllm-metal"$'\t'"$HOME/.venv-vllm-metal"$'\t'"official-venv"$'\t'"检测到官方 vllm-metal 虚拟环境"
    engine="${line%%$'\t'*}"
    path="${line#*$'\t'}"; path="${path%%$'\t'*}"
    case "$seen" in
      *"|${engine}@${path}|"*) ;;
      *) records="${records}${line}"$'\n'; seen="${seen}|${engine}@${path}|" ;;
    esac
  fi

  cfg_engine="$(config_engine)"
  if [[ -n "$cfg_engine" ]]; then
    case "$cfg_engine" in
      vllm|vllm-mlx|vllm-metal)
        case "$records" in
          "${cfg_engine}"$'\t'*|*$'\n'"${cfg_engine}"$'\t'*) ;;
          *) records="${records}${cfg_engine}"$'\t'"${INSTALL_DIR}"$'\t'"config"$'\t'"配置文件记录 VLLM_ENGINE=${cfg_engine}"$'\n' ;;
        esac
        ;;
    esac
  fi

  if [[ -z "$records" && -d "${INSTALL_DIR}" ]]; then
    records="all"$'\t'"${INSTALL_DIR}"$'\t'"legacy"$'\t'"检测到安装目录但无法识别具体引擎"$'\n'
  fi

  printf '%s' "$records"
}

print_external_vllm_hints() {
  local cmd
  for cmd in vllm vllm-mlx; do
    if command -v "$cmd" >/dev/null 2>&1; then
      warn "PATH 中检测到 ${cmd}: $(command -v "$cmd")。若不是 ${INSTALL_DIR} 下的命令，本脚本不会删除全局安装。"
    fi
  done
}

select_uninstall_target() {
  local records="$1" count=0 idx choice engine path kind note
  UNINSTALL_OPTION_ENGINE=()
  UNINSTALL_OPTION_PATH=()
  UNINSTALL_OPTION_NOTE=()

  if [[ -n "$UNINSTALL_TARGET" ]]; then
    validate_uninstall_target "$UNINSTALL_TARGET"
    return 0
  fi

  if [[ "$ENGINE_USER_SET" == "true" && -n "$ENGINE" ]]; then
    UNINSTALL_TARGET="$ENGINE"
    validate_uninstall_target "$UNINSTALL_TARGET"
    return 0
  fi

  while IFS=$'\t' read -r engine path kind note; do
    [[ -n "${engine:-}" ]] || continue
    count=$((count + 1))
    UNINSTALL_OPTION_ENGINE[$count]="$engine"
    UNINSTALL_OPTION_PATH[$count]="$path"
    UNINSTALL_OPTION_NOTE[$count]="$note"
  done <<< "$records"

  if (( count == 0 )); then
    error "未检测到由本脚本管理的 vLLM / vllm-mlx / vllm-metal 安装。"
    print_external_vllm_hints
    exit 1
  fi

  if (( count == 1 )); then
    UNINSTALL_TARGET="${UNINSTALL_OPTION_ENGINE[1]}"
    [[ "$UNINSTALL_TARGET" == "all" ]] && return 0
    info "检测到单个卸载目标: ${UNINSTALL_TARGET} (${UNINSTALL_OPTION_PATH[1]})"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    error "非交互模式检测到多个卸载目标，请指定 --uninstall-engine <vllm|vllm-mlx|vllm-metal|all>，或使用 --uninstall -e <engine> --yes。"
    exit 1
  fi

  echo ""
  info "检测到多个可卸载目标，请选择:"
  for ((idx=1; idx<=count; idx++)); do
    echo "  ${idx}) ${UNINSTALL_OPTION_ENGINE[$idx]} - ${UNINSTALL_OPTION_PATH[$idx]} (${UNINSTALL_OPTION_NOTE[$idx]})"
  done
  echo "  $((count + 1))) all - 清理 ${INSTALL_DIR} 和 ~/.venv-vllm-metal"
  echo "  0) 取消"
  read -rp "请选择 [0-$((count + 1))]: " choice

  if [[ "$choice" == "0" || -z "$choice" ]]; then
    info "已取消卸载"
    exit 0
  elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$count" ]]; then
    UNINSTALL_TARGET="${UNINSTALL_OPTION_ENGINE[$choice]}"
  elif [[ "$choice" == "$((count + 1))" ]]; then
    UNINSTALL_TARGET="all"
  else
    error "无效选择: $choice"
    exit 1
  fi
}

confirm_uninstall_target() {
  local target="$1"
  if $ASSUME_YES; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    error "非交互卸载需要 --yes，并建议指定 --uninstall-engine。"
    exit 1
  fi
  read -rp "确认卸载 ${target}？此操作不可恢复 [y/N]: " _ans
  [[ "$_ans" =~ ^[Yy]$ ]] || { info "已取消卸载"; exit 0; }
}

stop_and_remove_service() {
  if command -v systemctl &>/dev/null; then
    sudo systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    sudo systemctl disable ${SERVICE_NAME} 2>/dev/null || true
    sudo rm -f /etc/systemd/system/${SERVICE_NAME}.service
    sudo systemctl daemon-reload 2>/dev/null || true
  elif command -v launchctl &>/dev/null && [[ "$(uname)" == "Darwin" ]]; then
    launchctl stop ${SERVICE_NAME} 2>/dev/null || true
    launchctl unload ~/Library/LaunchAgents/${SERVICE_NAME}.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/${SERVICE_NAME}.plist
  fi
}

pip_uninstall_from_venv() {
  local venv="$1"; shift
  [[ -x "${venv}/bin/python" ]] || return 0
  "${venv}/bin/python" -m pip uninstall -y "$@" >/dev/null 2>&1 || true
}

remove_runtime_files_if_config_matches() {
  local target="$1" cfg_engine
  cfg_engine="$(config_engine)"
  [[ "$cfg_engine" == "$target" ]] || return 0
  rm -f "${CONFIG_FILE}" \
        "${INSTALL_DIR}/start.sh" \
        "${INSTALL_DIR}/start_model.sh" \
        "${INSTALL_DIR}/start_multi.sh" \
        "${INSTALL_DIR}/stop.sh" \
        "${INSTALL_DIR}/test_api.sh"
}

run_uninstall() {
  local records target active_engine
  records="$(detect_installed_engine_records)"
  select_uninstall_target "$records"
  target="$UNINSTALL_TARGET"
  validate_uninstall_target "$target"
  active_engine="$(config_engine)"

  echo ""
  info "准备卸载: ${target}"
  if [[ "$target" == "all" ]]; then
    warn "将删除目录: ${INSTALL_DIR}"
    [[ -d "$HOME/.venv-vllm-metal" ]] && warn "将删除目录: $HOME/.venv-vllm-metal"
  else
    warn "如当前服务配置使用 ${target}，将停止并移除 ${SERVICE_NAME} 服务配置。"
    warn "将卸载 ${target} 相关 Python 包；模型目录 ${MODEL_DIR} 会保留。"
    [[ "$target" == "vllm-metal" && -d "$HOME/.venv-vllm-metal" ]] && warn "将删除目录: $HOME/.venv-vllm-metal"
  fi

  confirm_uninstall_target "$target"
  if [[ "$target" == "all" || "$active_engine" == "$target" ]]; then
    stop_and_remove_service
  elif [[ -n "$active_engine" ]]; then
    info "当前服务配置使用 ${active_engine}，本次卸载 ${target} 不移除 ${SERVICE_NAME} 服务。"
  else
    info "未找到当前服务引擎配置，本次仅清理 ${target} 包和相关目录。"
  fi

  case "$target" in
    all)
      rm -rf "${INSTALL_DIR}"
      rm -rf "$HOME/.venv-vllm-metal"
      ;;
    vllm-metal)
      pip_uninstall_from_venv "${VENV_DIR}" vllm-metal
      if [[ -L "${VENV_DIR}" && -d "$HOME/.venv-vllm-metal" ]]; then
        rm -f "${VENV_DIR}"
      fi
      rm -rf "$HOME/.venv-vllm-metal"
      remove_runtime_files_if_config_matches "$target"
      ;;
    vllm-mlx)
      pip_uninstall_from_venv "${VENV_DIR}" vllm-mlx
      remove_runtime_files_if_config_matches "$target"
      ;;
    vllm)
      pip_uninstall_from_venv "${VENV_DIR}" vllm
      remove_runtime_files_if_config_matches "$target"
      ;;
  esac

  print_external_vllm_hints
  success "${target} 已卸载"
}

if $UNINSTALL; then
  run_uninstall
  exit 0
fi

if $LIST_MODELS; then
  list_model_catalog
  exit 0
fi

DEFAULT_MODEL=$(resolve_model_alias "$DEFAULT_MODEL")

# --------------------------- 版本检测 ----------------------------------------
get_latest_version() {
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || pkg=$(engine_version_package)

  # 只有实际安装/目标包是 vllm-metal 时才查询 vllm-metal release。
  # Mac 上的 vLLM Metal 路径可能仅安装 vllm 核心包，不能跨包比较版本号。
  if [[ "$pkg" == "vllm-metal" ]]; then
    local latest_version github_version
    latest_version=$(curl -fsSL "https://pypi.org/pypi/${pkg}/json" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null || echo "")
    local tmp_json
    tmp_json=$(mktemp "${TMPDIR:-/tmp}/vllm-metal-release.XXXXXX.json")
    if fetch_release_json "https://api.github.com/repos/vllm-project/vllm-metal/releases/latest" "$tmp_json" 2>/dev/null; then
      github_version=$(python3 - "$tmp_json" <<'PY' 2>/dev/null || echo ""
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    print(json.load(fh).get("tag_name", "").lstrip("v"))
PY
)
    else
      github_version=""
    fi
    rm -f "$tmp_json"
    if [[ -z "$latest_version" ]]; then
      latest_version="$github_version"
    elif [[ -n "$github_version" ]]; then
      local cmp
      cmp=$(compare_versions "$github_version" "$latest_version")
      [[ "$cmp" == "1" ]] && latest_version="$github_version"
    fi
    echo "$latest_version"
    return
  fi

  # 从 PyPI 获取远端最新版本；安装兼容性在实际安装时由 resolver 判断。
  local latest_version
  latest_version=$(curl -fsSL "https://pypi.org/pypi/${pkg}/json" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null || echo "")

  echo "$latest_version"
}

remember_blocked_update() {
  local pkg="$1" version="$2"
  [[ -n "$pkg" && -n "$version" ]] || return 0
  mkdir -p "${INSTALL_DIR}" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "${OS:-unknown}" "${ARCH:-unknown}" "$pkg" "$version" >> "${UPDATE_SKIP_CACHE_FILE}"
}

is_blocked_update() {
  local pkg="$1" version="$2"
  [[ -f "${UPDATE_SKIP_CACHE_FILE}" ]] || return 1
  grep -Fqx "${OS:-unknown}"$'\t'"${ARCH:-unknown}"$'\t'"$pkg"$'\t'"$version" "${UPDATE_SKIP_CACHE_FILE}" 2>/dev/null
}

engine_version_package() {
  if [[ "$ENGINE" == "vllm-metal" ]]; then
    if [[ -d "${VENV_DIR}" && -x "${VENV_DIR}/bin/python" ]]; then
      if venv_has_distribution "${VENV_DIR}" "vllm-metal"; then
        echo "vllm-metal"
        return
      fi
      if venv_has_distribution "${VENV_DIR}" "vllm"; then
        echo "vllm"
        return
      fi
    fi
    echo "vllm"
    return
  fi
  engine_pypi_package
}

get_installed_version() {
  if [[ ! -f "${VENV_DIR}/bin/python" ]] || [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    echo ""
    return
  fi

  source "${VENV_DIR}/bin/activate" 2>/dev/null
  local pkg
  pkg=$(engine_version_package)
  VERSION_PACKAGE_TARGET="$pkg"
  local dist_version
  dist_version=$(python - "$pkg" <<'PY' 2>/dev/null || true
import importlib.metadata as metadata
import sys
try:
    print(metadata.version(sys.argv[1]))
except metadata.PackageNotFoundError:
    pass
PY
)
  if [[ -n "$dist_version" ]]; then
    echo "$dist_version"
    return
  fi

  local module
  module=$(engine_python_module)
  local version
  version=$(python -c "import ${module}; print(${module}.__version__)" 2>/dev/null || echo "")
  echo "$version"
}

read_config_value() {
  local key="$1"
  [[ -f "${CONFIG_FILE}" ]] || return 0
  awk -F= -v key="$key" '
    $1 == key {
      value=$0
      sub("^[^=]*=", "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'\''|'\''$/, "", value)
      print value
      exit
    }
  ' "${CONFIG_FILE}" 2>/dev/null || true
}

adopt_existing_engine_from_config() {
  [[ "$ENGINE_USER_SET" == "true" ]] && return 0
  local cfg_engine
  cfg_engine="$(config_engine)"
  case "$cfg_engine" in
    vllm|vllm-mlx|vllm-metal)
      if [[ -d "${VENV_DIR}" || -f "${CONFIG_FILE}" ]]; then
        ENGINE="$cfg_engine"
      fi
      ;;
  esac

  [[ -n "$cfg_engine" ]] && return 0

  local records engine path kind note count=0 detected_engine=""
  records="$(detect_installed_engine_records)"
  while IFS=$'\t' read -r engine path kind note; do
    [[ -n "${engine:-}" ]] || continue
    [[ "$engine" == "all" ]] && continue
    count=$((count + 1))
    detected_engine="$engine"
  done <<< "$records"

  if (( count == 1 )); then
    ENGINE="$detected_engine"
  fi
}

load_existing_runtime_config() {
  [[ -f "${CONFIG_FILE}" ]] || return 0

  local cfg_model cfg_port cfg_gpu_util cfg_max_len
  cfg_model="$(read_config_value VLLM_MODEL)"
  cfg_port="$(read_config_value VLLM_PORT)"
  cfg_gpu_util="$(read_config_value VLLM_GPU_MEMORY_UTILIZATION)"
  cfg_max_len="$(read_config_value VLLM_MAX_MODEL_LEN)"

  if [[ "$MODEL_USER_SET" != "true" && -n "$cfg_model" ]]; then
    DEFAULT_MODEL="$cfg_model"
  fi
  [[ -n "$cfg_port" ]] && DEFAULT_PORT="$cfg_port"
  [[ -n "$cfg_gpu_util" ]] && DEFAULT_GPU_MEMORY_UTILIZATION="$cfg_gpu_util"
  [[ -n "$cfg_max_len" ]] && DEFAULT_MAX_MODEL_LEN="$cfg_max_len"
}

compare_versions() {
  local v1="$1"
  local v2="$2"

  if [[ "$v1" == "$v2" ]]; then
    echo "0"
    return
  fi

  # 优先用 packaging.version (PEP 440 兼容，支持 rc/post/dev 等后缀)
  local result
  result=$(python3 - "$v1" "$v2" <<'PY' 2>/dev/null || true
import sys
try:
    from packaging.version import Version
    a, b = Version(sys.argv[1]), Version(sys.argv[2])
    print(0 if a == b else (1 if a > b else -1))
except Exception:
    pass
PY
)
  if [[ -n "$result" ]]; then
    echo "$result"
    return
  fi

  # Fallback: 朴素数字段比较 (仅在 packaging 不可用时)
  local IFS='.'
  local i
  # 先剥掉非数字后缀 (如 0.21.0rc1 -> 0.21.0)
  local clean1="${v1%%[^0-9.]*}"
  local clean2="${v2%%[^0-9.]*}"
  local ver1=($clean1) ver2=($clean2)

  for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
  for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do ver2[i]=0; done

  for ((i=0; i<${#ver1[@]}; i++)); do
    local a="${ver1[i]:-0}" b="${ver2[i]:-0}"
    if ((10#$a > 10#$b)); then echo "1"; return; fi
    if ((10#$a < 10#$b)); then echo "-1"; return; fi
  done
  echo "0"
}

is_apple_silicon() {
  [[ "$(uname)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]
}

python_is_arm64() {
  local python_bin="$1"
  [[ -x "$python_bin" ]] || return 1
  "$python_bin" - <<'PY' >/dev/null 2>&1
import platform
import sys
sys.exit(0 if platform.machine() == "arm64" else 1)
PY
}

python_version_major_minor() {
  local python_bin="$1"
  "$python_bin" - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
}

fetch_release_json() {
  local url="$1" out_file="$2"
  if command -v adl >/dev/null 2>&1; then
    adl "$url" "$(dirname "$out_file")" "$(basename "$out_file")" >/dev/null 2>&1
  else
    curl -fsSL "$url" -o "$out_file"
  fi
}

extract_release_asset_url() {
  local json_file="$1" pattern="${2:-\\.whl$}"
  python3 - "$json_file" "$pattern" <<'PY'
import json
import re
import sys

json_file, pattern = sys.argv[1], sys.argv[2]
with open(json_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)
assets = data.get("assets", [])
rx = re.compile(pattern, re.I)
preferred = []
fallback = []
for asset in assets:
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if not (rx.search(name) and "source" not in name.lower()):
        continue
    fallback.append(url)
    if "macos" in name.lower() and "arm64" in name.lower():
        preferred.append(url)
if preferred:
    print(preferred[0])
elif fallback:
    print(fallback[0])
PY
}

check_existing_installation() {
  sync_official_metal_venv
  if [[ ! -d "${VENV_DIR}" ]] || [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    info "未检测到已安装的 ${ENGINE}，将进行全新安装"
    return 1
  fi
  
  # vllm-metal 引擎: 只接受 Apple Silicon arm64 + Python 3.12 的官方 Metal 路径
  if [[ "$ENGINE" == "vllm-metal" ]]; then
    local installed_version
    installed_version=$(get_installed_version)
    if [[ -n "$installed_version" ]]; then
      source "${VENV_DIR}/bin/activate" 2>/dev/null || true
      if ! python_is_arm64 "${VENV_DIR}/bin/python"; then
        warn "检测到 vllm-metal 不是原生 arm64 Python 环境，将重新安装"
        return 1
      fi
      # 区分版本尺度: 独立 vllm-metal 包版本是 0.x.dev 系列，不能和 vLLM 核心 0.22 门槛比较。
      # 仅当环境里只有 vLLM 核心包(尚无独立 metal 包)时，才用核心版本门槛判断是否过旧。
      local metal_pkg
      metal_pkg=$(engine_version_package)
      if [[ "$metal_pkg" == "vllm" ]]; then
        local cmp
        cmp=$(compare_versions "$installed_version" "0.22.0")
        if [[ "$cmp" == "-1" ]]; then
          info "vLLM 核心包版本过旧, 当前 ${installed_version}, 将重新安装 vllm-metal"
          return 1
        fi
      fi
      # vllm-metal 通过 entry point 注册插件，验证用 import vllm_metal
      # (不存在 vllm.platform_plugins 这个模块，旧检测必然失败)。
      if python -c "import vllm_metal" 2>/dev/null; then
        success "vllm-metal ${installed_version} 已安装且 Metal 插件可用"
        return 2  # already_current
      fi
      warn "vllm-metal 已安装但 Metal 插件不可用, 将重新安装"
      return 1
    fi
    # 无法获取版本, 重新安装
    return 1
  fi

  local installed_version
  installed_version=$(get_installed_version)
  local version_pkg
  version_pkg=$(engine_version_package)
  LATEST_REMOTE_PACKAGE="$version_pkg"
  LATEST_REMOTE_VERSION=""
  
  if [[ -z "$installed_version" ]]; then
    warn "检测到 vLLM 安装目录但无法获取版本号"
    return 1
  fi

  local display_name="${ENGINE}"
  local update_target_label="${ENGINE}"
  if [[ "$ENGINE" == "vllm-metal" && "$version_pkg" == "vllm" ]]; then
    display_name="vllm-metal (引擎) · 当前仅装有核心包 vllm"
    update_target_label="vLLM 核心包 (vllm)"
  elif [[ "$ENGINE" == "vllm-metal" ]]; then
    update_target_label="vllm-metal 插件"
  fi

  info "${display_name}: 已安装版本 ${installed_version}，正在检查 ${update_target_label} 是否有更新..."

  # 如果指定了版本号，检查是否需要降级/升级
  if [[ -n "$VLLM_VERSION" ]]; then
    if [[ "$VLLM_VERSION" != "$installed_version" ]]; then
      local cmp
      cmp=$(compare_versions "$VLLM_VERSION" "$installed_version")
      if [[ "$cmp" == "1" ]]; then
        info "目标版本 ${VLLM_VERSION} 高于当前版本 ${installed_version}，将升级"
      elif [[ "$cmp" == "-1" ]]; then
        info "目标版本 ${VLLM_VERSION} 低于当前版本 ${installed_version}，将降级"
      else
        info "目标版本与当前版本相同，无需操作"
        success "${ENGINE} ${installed_version} 已是最新版本"
        exit 0
      fi
      return 0
    else
      info "指定的版本 ${VLLM_VERSION} 已安装，无需操作"
      success "${ENGINE} ${installed_version} 已是最新版本"
      exit 0
    fi
  fi
  
  # 未指定版本，检查是否有新版本
  local latest_version
  latest_version=$(get_latest_version "$version_pkg")
  LATEST_REMOTE_VERSION="$latest_version"

  if [[ -z "$latest_version" ]]; then
    warn "无法获取最新版本信息（当前 ${installed_version}），将重新安装。"
    return 0
  fi

  if is_blocked_update "$version_pkg" "$latest_version"; then
    UPDATE_PLATFORM_BLOCKED=true
    info "${update_target_label} 远端最新为 ${latest_version}，但已记录其在本平台 (${OS}/${ARCH}) 缺少可用 wheel，跳过重复尝试。"
    info "如需强制重试，删除缓存即可: rm -f ${UPDATE_SKIP_CACHE_FILE}"
    return 2
  fi

  local cmp
  cmp=$(compare_versions "$latest_version" "$installed_version")

  if [[ "$cmp" == "0" ]]; then
    success "${ENGINE} ${installed_version} 已是最新版本"
    return 2
  elif [[ "$cmp" == "-1" ]]; then
    warn "当前 ${version_pkg} ${installed_version} 高于远端最新版本 ${latest_version}，可能是开发版或本地构建，保留当前版本并跳过重装。"
    return 2
  else
    # 有新版本
    echo ""
    info "更新对象: ${GREEN}${update_target_label}${NC} (pip 包: ${version_pkg})"
    info "${update_target_label} 发现新版本: ${RED}${installed_version}${NC} → ${GREEN}${latest_version}${NC}"
    VERSION_PACKAGE_TARGET="$version_pkg"
    if [[ "$OS" == "macos" && "$ENGINE" == "vllm" ]]; then
      warn "macOS 上升级 vLLM 极易导致依赖崩溃 (如 tokenspeed-mla 冲突)。"
    fi

    if [[ "$AUTO_UPDATE" == "true" ]]; then
      if [[ "$OS" == "macos" && "$ENGINE" == "vllm" ]]; then
        read -rp "您确定要在 macOS 环境下进行风险升级吗? (y/N): " risk_confirm
        if [[ ! "$risk_confirm" =~ ^[Yy]$ ]]; then
          info "已取消风险升级，保持当前稳定版本。"
          return 1
        fi
      fi
      if [[ "$ENGINE" == "vllm-metal" && "$version_pkg" == "vllm" ]]; then
        info "准备更新 ${update_target_label} 到 v${latest_version} (注意: 更新的是 vLLM 核心包, 而非 vllm-metal 插件本体)..."
      else
        info "准备更新 ${update_target_label} 到 v${latest_version}..."
      fi
    else
      read -rp "是否更新到 v${latest_version}? (Y/n): " update_choice
      if [[ "$update_choice" =~ ^[Nn]$ ]]; then
        info "取消更新"
        print_usage
        exit 0
      fi
    fi
    
    VLLM_VERSION="$latest_version"
  fi
  
  return 0
}

confirm() {
  local prompt="${1:-是否继续?}"
  local default="${2:-n}"
  local response suffix

  if [[ "$default" =~ ^[Yy]$ ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  if [[ -t 0 ]]; then
    read -rp "$prompt $suffix: " response
    response="${response:-$default}"
  else
    response="$default"
    info "非交互模式，自动选择: ${prompt} -> ${response}"
  fi

  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# --------------------------- 系统检测 ----------------------------------------
detect_os() {
  if [[ "$(uname)" == "Darwin" ]]; then
    OS="macos"
    ARCH="$(uname -m)"
    info "检测到 macOS (架构: ${ARCH})"
  else
    OS="linux"
    ARCH="$(uname -m)"
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      DISTRO="${ID}"
      info "检测到 Linux: ${DISTRO} (架构: ${ARCH})"
    else
      DISTRO="unknown"
      warn "无法检测 Linux 发行版"
    fi
  fi
}

get_cpu_info() {
  if [[ "$OS" == "macos" ]]; then
    CPU_NAME=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown CPU")
    CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "0")
    CPU_PERF_CORES=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo "$CPU_CORES")
  else
    CPU_NAME=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown CPU")
    CPU_CORES=$(nproc 2>/dev/null || echo "0")
    CPU_PERF_CORES="$CPU_CORES"
  fi
}

get_memory_info() {
  if [[ "$OS" == "macos" ]]; then
    TOTAL_MEM_GB=$(($(sysctl -n hw.memsize 2>/dev/null || echo "0") / 1073741824))
  else
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1048576))
  fi

  if [[ "$TOTAL_MEM_GB" -lt 1 ]]; then
    TOTAL_MEM_GB=0
  fi
}

check_gpu() {
  HAS_GPU=false
  GPU_TYPE="cpu"

  if [[ "$OS" == "macos" ]]; then
    # Check for Apple Silicon (MPS)
    if [[ "$(uname -m)" == "arm64" ]]; then
      HAS_GPU=true
      GPU_TYPE="mps"
    fi
  elif command -v nvidia-smi &> /dev/null; then
    # Check for NVIDIA GPU (CUDA)
    HAS_GPU=true
    GPU_TYPE="cuda"
  elif command -v rocminfo &> /dev/null; then
    # Check for AMD GPU (ROCm)
    HAS_GPU=true
    GPU_TYPE="rocm"
  fi
}

get_gpu_details() {
  GPU_NAME=""
  GPU_MEMORY_GB=0
  GPU_COUNT=1
  
  if [[ "$GPU_TYPE" == "cuda" ]]; then
    # NVIDIA GPU 详情
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 | xargs || echo "Unknown NVIDIA GPU")
    local gpu_mem_mb
    gpu_mem_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -n1 | awk '{print int($1)}' || echo "0")
    GPU_MEMORY_GB=$((gpu_mem_mb / 1024))
    GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l | awk '{print $1+0}')
    [[ "${GPU_COUNT:-0}" -lt 1 ]] && GPU_COUNT=1
    
  elif [[ "$GPU_TYPE" == "mps" ]]; then
    # Apple Silicon 统一内存
    if [[ "$OS" == "macos" ]]; then
      local chip_name
      chip_name=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
      if [[ "$chip_name" == *"M4"* ]]; then
        GPU_NAME="Apple M4 Series"
      elif [[ "$chip_name" == *"M3"* ]]; then
        GPU_NAME="Apple M3 Series"
      elif [[ "$chip_name" == *"M2"* ]]; then
        GPU_NAME="Apple M2 Series"
      elif [[ "$chip_name" == *"M1"* ]]; then
        GPU_NAME="Apple M1 Series"
      else
        GPU_NAME="Apple Silicon"
      fi
      GPU_MEMORY_GB=$TOTAL_MEM_GB  # 统一内存
    fi
    
  elif [[ "$GPU_TYPE" == "rocm" ]]; then
    # AMD GPU
    GPU_NAME=$(rocminfo 2>/dev/null | awk '/Marketing Name:/ {sub(/^[^:]*: */,""); print; exit}')
    [[ -z "$GPU_NAME" ]] && GPU_NAME="Unknown AMD GPU"
    if command -v rocm-smi &>/dev/null; then
      local gpu_mem_mb
      gpu_mem_mb=$(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F',' 'NR==2 {print int($2/1048576); exit}')
      GPU_MEMORY_GB=$(( ${gpu_mem_mb:-0} / 1024 ))
    fi
  fi
}

detect_hardware() {
  get_cpu_info
  get_memory_info
  check_gpu
  if $HAS_GPU; then
    get_gpu_details
  else
    GPU_TYPE="cpu"
    GPU_MEMORY_GB=0
  fi

  if [[ "${VLLM_VERBOSE:-0}" == "1" ]]; then
    echo ""
    info "CPU: ${CPU_NAME} (${CPU_CORES} 核心)"
    info "内存: ${TOTAL_MEM_GB} GB"
    if $HAS_GPU && [[ -n "$GPU_NAME" ]]; then
      if [[ "$GPU_TYPE" == "mps" ]]; then
        info "GPU: ${GPU_NAME} (统一内存 ${GPU_MEMORY_GB} GB)"
      else
        info "GPU: ${GPU_NAME} (显存 ${GPU_MEMORY_GB} GB${GPU_COUNT:+, ${GPU_COUNT}卡})"
      fi
    elif ! $HAS_GPU; then
      warn "未检测到 GPU，将使用 CPU 模式（推理速度较慢）"
    fi
  else
    local hw_line
    if [[ "$GPU_TYPE" == "mps" ]]; then
      hw_line="${CPU_NAME} / ${TOTAL_MEM_GB}GB 统一内存 / ${GPU_TYPE}"
    elif $HAS_GPU; then
      hw_line="${CPU_NAME} / ${TOTAL_MEM_GB}GB / ${GPU_NAME:-$GPU_TYPE} ${GPU_MEMORY_GB}GB"
    else
      hw_line="${CPU_NAME} / ${TOTAL_MEM_GB}GB / CPU only"
    fi
    info "硬件: ${hw_line}"
  fi
}

check_compiler() {
  if [[ "$OS" != "macos" ]]; then return 0; fi
  
  info "正在验证 C++ 编译器可用性..."
  
  # 等待 Xcode 命令行工具安装完成
  wait_for_xcode() {
    local max_wait=300
    local waited=0
    local interval=5
    
    warn "检测到 Xcode 命令行工具正在安装或未安装..."
    info "脚本将等待安装完成，请确保在弹窗中点击 '安装'..."
    echo ""
    
    while [ $waited -lt $max_wait ]; do
      if [ -d "/Library/Developer/CommandLineTools/usr/bin/c++" ]; then
        local test_file="/tmp/compiler_test_$$.cpp"
        echo "int main(){return 0;}" > "$test_file"
        if c++ "$test_file" -o "/tmp/compiler_test_$$.out" 2>/dev/null; then
          rm -f "$test_file" "/tmp/compiler_test_$$.out"
          return 0
        fi
        rm -f "$test_file" "/tmp/compiler_test_$$.out"
      fi
      
      if pgrep -q "Install Command Line Developer Tools"; then
        printf "\r${YELLOW}[等待中]${NC} 正在等待 Xcode 命令行工具安装... (已等待 ${waited}s)"
      else
        printf "\r${YELLOW}[等待中]${NC} 正在检测安装状态... (已等待 ${waited}s)"
      fi
      
      sleep $interval
      waited=$((waited + interval))
    done
    
    echo ""
    return 1
  }
  
  local test_file="/tmp/compiler_test_$$.cpp"
  echo "int main(){return 0;}" > "$test_file"
  
  if ! c++ "$test_file" -o "/tmp/compiler_test_$$.out" >/dev/null 2>&1; then
    rm -f "$test_file" "/tmp/compiler_test_$$.out" 2>/dev/null
    
    if wait_for_xcode; then
      success "Xcode 命令行工具安装完成，C++ 编译器验证通过"
      return 0
    fi
    
    echo ""
    warn "检测到编译器不可用 (Xcode 命令行工具尚未安装或安装失败)。"
    info "解决方案："
    info "  1. 运行命令: ${BOLD}xcode-select --install${NC}"
    info "  2. 在弹出的窗口中点击 '安装'"
    info "  3. 等待安装完成后重新运行此脚本"
    info ""
    info "或者手动指定 Homebrew 安装 clang："
    info "  ${BOLD}brew install gcc${NC}"
    error "缺失有效的 C++ 编译环境，安装终止。"
    exit 1
  fi
  rm -f "$test_file" "/tmp/compiler_test_$$.out"
  success "C++ 编译器验证通过"
}

check_hardware_requirements() {
  # 验证编译器 (macOS 编译 vLLM 必需)
  check_compiler

  MEETS_MINIMUM=false
  RECOMMENDED_MODELS=""

  # 最低要求：4GB 内存（CPU 模式）
  if [[ "$TOTAL_MEM_GB" -ge 4 ]]; then
    MEETS_MINIMUM=true
  fi
  
  if ! $MEETS_MINIMUM; then
    error "✗ 硬件不满足最低要求"
    echo ""
    warn "最低配置要求："
    warn "  - 内存: 4 GB（推荐 8 GB 以上）"
    warn "  - CPU: 支持 AVX2 指令集"
    warn "  - 存储: 至少 10 GB 可用空间"
    echo ""
    error "当前配置无法运行 vLLM，建议升级硬件或使用云服务"
    exit 1
  fi
  
  # 检查磁盘空间
  local free_space_gb
  if [[ "$OS" == "macos" ]]; then
    free_space_gb=$(df -g . | awk 'NR==2 {print $4}')
  else
    free_space_gb=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
  fi
  
  if [[ "$free_space_gb" -lt 100 ]]; then
    local ext_hint=""
    if [[ "$OS" == "macos" ]]; then
      local ext_line
      ext_line=$(df -g | awk '$9 ~ "^/Volumes/" && $2 > 500 {printf "%s 有 %sGB", $9, $4; exit}' || true)
      [[ -n "$ext_line" ]] && ext_hint="，外置盘 ${ext_line}"
    fi
    warn "系统盘可用 ${free_space_gb}GB（建议 200GB+${ext_hint}）"
  else
    info "系统盘可用 ${free_space_gb} GB"
  fi
  
  # 基于硬件推荐可用模型
  generate_model_recommendations
}

generate_model_recommendations() {
  local recommendations=()
  local cpu_only=false
  local limited_gpu=false
  local medium_gpu=false
  local high_gpu=false
  local ultra_gpu=false
  
  # 根据硬件分类
  if [[ "$GPU_TYPE" == "cpu" ]]; then
    cpu_only=true
  elif [[ "$GPU_MEMORY_GB" -le 6 ]]; then
    limited_gpu=true
  elif [[ "$GPU_MEMORY_GB" -le 12 ]]; then
    medium_gpu=true
  elif [[ "$GPU_MEMORY_GB" -le 24 ]]; then
    high_gpu=true
  else
    ultra_gpu=true
  fi
  
  [[ "${VLLM_VERBOSE:-0}" == "1" ]] && info "基于当前硬件配置，推荐以下模型："
  
  # CPU 模式推荐
  if $cpu_only; then
    echo -e "  ${YELLOW}[CPU 模式 - 仅推荐小模型]${NC}"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  推荐模型                          参数量    内存需求"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Qwen/Qwen2.5-0.5B-Instruct       0.5B      ~1 GB"
    echo "  Qwen/Qwen2.5-1.5B-Instruct       1.5B      ~3 GB"
    echo "  meta-llama/Llama-3.2-1B-Instruct 1B        ~2 GB"
    echo "  Qwen/Qwen2.5-3B-Instruct         3B        ~6 GB (较慢)"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${YELLOW}提示: CPU 模式推理速度较慢，建议使用 3B 以下模型${NC}"
    echo ""
    
    RECOMMENDED_MODELS="Qwen/Qwen2.5-1.5B-Instruct"
    
  # 小显存 GPU (≤6GB)
  elif $limited_gpu; then
    echo -e "  ${YELLOW}[小显存 GPU - 推荐 1B-3B 模型]${NC}"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  推荐模型                          参数量    显存需求"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Qwen/Qwen2.5-1.5B-Instruct       1.5B      ~3 GB"
    echo "  Qwen/Qwen2.5-3B-Instruct         3B        ~6 GB"
    echo "  meta-llama/Llama-3.2-3B-Instruct 3B        ~6 GB"
    echo "  google/gemma-2-2b-it             2B        ~4 GB"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    RECOMMENDED_MODELS="Qwen/Qwen2.5-3B-Instruct"
    
  # 中等显存 GPU (8-12GB)
  elif $medium_gpu; then
    echo -e "  ${GREEN}[中等显存 GPU - 推荐 7B-8B 模型]${NC}"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  推荐模型                          参数量    显存需求"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Qwen/Qwen2.5-7B-Instruct         7B        ~14 GB"
    echo "  meta-llama/Llama-3.1-8B-Instruct 8B        ~16 GB"
    echo "  google/gemma-2-9b-it             9B        ~18 GB"
    echo "  mistralai/Ministral-8B-Instruct  8B        ~16 GB"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${YELLOW}提示: 可降低 --max-model-len 以运行更大模型${NC}"
    echo ""
    
    RECOMMENDED_MODELS="Qwen/Qwen2.5-7B-Instruct"
    
  # 大显存 GPU (16-24GB)
  elif $high_gpu; then
    echo -e "  ${GREEN}[大显存 GPU - 推荐 7B-14B 模型]${NC}"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  推荐模型                          参数量    显存需求"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Qwen/Qwen2.5-7B-Instruct         7B        ~14 GB"
    echo "  Qwen/Qwen2.5-14B-Instruct        14B       ~28 GB (需量化)"
    echo "  meta-llama/Llama-3.1-8B-Instruct 8B        ~16 GB"
    echo "  mistralai/Mistral-7B-Instruct    7B        ~14 GB"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${YELLOW}提示: 可使用 GPTQ/AWQ 量化版运行更大模型${NC}"
    echo ""
    
    RECOMMENDED_MODELS="Qwen/Qwen2.5-7B-Instruct"
    
  # 超大显存 GPU (≥40GB)
  elif $ultra_gpu; then
    if [[ "${VLLM_VERBOSE:-0}" == "1" ]]; then
      echo -e "  ${GREEN}[超大显存 GPU - 可运行 14B-70B+ 模型]${NC}"
      echo "  推荐模型 (M4 Max 128GB):"
      echo -e "    ${GREEN}qwen3.6-27b${NC}                ~54GB  编码+文档主力 (Dense, SWE-bench 77.2%)"
      echo -e "    ${CYAN}qwen3.6-35b-a3b${NC}            ~70GB  高速编码 (MoE 3B active, 速度3-4x)"
      echo "    qwen3-coder-30b-a3b        ~64GB  编码 MoE 备选"
      echo "    qwen2.5-coder-32b          ~64GB  编码稳妥备选"
      echo "    deepseek-r1-distill-qwen-32b ~64GB  推理/代码审查"
      echo "    qwen3-30b-a3b              ~60GB  PRD/方案"
      echo -e "    ${CYAN}gemma3-27b${NC}                 ~54GB  多模态"
      echo "    详见: $0 --list-models"
      echo ""
    else
      info "硬件适合: qwen3.6-27b / qwen3.6-35b-a3b / qwen3-coder-30b-a3b"
      info "(详细模型表: VLLM_VERBOSE=1 $0  或  $0 --list-models)"
    fi

    RECOMMENDED_MODELS="Qwen/Qwen3.6-27B"

    # 针对 128GB 内存精调 GPU 显存利用率
    if [[ "$GPU_TYPE" == "mps" && "$TOTAL_MEM_GB" -ge 128 ]]; then
      DEFAULT_GPU_MEMORY_UTILIZATION=0.90
    fi
  fi

  # Apple Silicon 特殊提示（仅 verbose 显示完整版）
  if [[ "$GPU_TYPE" == "mps" && "${VLLM_VERBOSE:-0}" == "1" ]]; then
    echo -e "  ${CYAN}[Apple Silicon 提示]${NC}"
    echo "  - 使用统一内存，系统与 GPU 共享"
    if [[ "$TOTAL_MEM_GB" -ge 64 ]]; then
      echo "  - 建议 --gpu-memory-utilization=0.8 (留系统开销)"
    else
      echo "  - 建议 --gpu-memory-utilization=0.7 避免 OOM"
    fi
    echo ""
  fi
}

check_python() {
  info "正在检查 Python 环境..."
  
  # vllm-metal 要求 Python >= 3.12
  local min_python_version="3.10"
  local python_constraint=">=3.10"
  local required_major_minor=""
  local python_candidates=(3.12 3.13 3.14 3.11 3.10)
  if [[ "$ENGINE" == "vllm-metal" ]]; then
    min_python_version="3.12"
    python_constraint=">=3.12"
    required_major_minor="3.12"
    python_candidates=(3.12)
    info "vllm-metal 要求 Python >= 3.12"
  fi
  if [[ -n "$PYTHON_VERSION" ]]; then
    min_python_version="$PYTHON_VERSION"
    [[ "$min_python_version" == *.*.* ]] && min_python_version="${min_python_version%.*}"
    python_constraint="$PYTHON_VERSION"
    python_candidates=("$PYTHON_VERSION")
    if [[ "$ENGINE" == "vllm-metal" && "${PYTHON_VERSION%%.*}.${PYTHON_VERSION#*.}" != "3.12" ]]; then
      error "vllm-metal 仅支持 Python 3.12，当前指定为 ${PYTHON_VERSION}"
      exit 1
    fi
    info "用户指定 Python ${PYTHON_VERSION}，将优先使用该版本"
  fi
  
  local python_found=false
  PYTHON_CMD=""

  # 1. 优先使用 PATH 中的 Python，Xcode CLT 只作为编译环境判断。
  if [[ "$OS" == "macos" ]]; then
    if xcode-select -p &>/dev/null; then
      info "检测到 Xcode 命令行工具，开始查找可用 Python..."
      for ver in "${python_candidates[@]}"; do
        local cmd="python${ver}"
        if PYTHON_CMD="$(find_cmd "$cmd")"; then
          # 验证这个 python 是不是真实的 (不是 shim)
          if ! "$PYTHON_CMD" --version 2>&1 | grep -q "install requested"; then
            if [[ "$ENGINE" == "vllm-metal" ]]; then
              if ! python_is_arm64 "$PYTHON_CMD"; then
                continue
              fi
              if [[ "$(python_version_major_minor "$PYTHON_CMD")" != "$required_major_minor" ]]; then
                continue
              fi
            fi
            python_found=true
            success "使用 Python: $PYTHON_CMD"
            break
          fi
        fi
      done
    fi
  fi

  # 2. 尝试使用 uv (现代、独立、极速)
  local uv_cmd=""
  uv_cmd="$(find_cmd uv 2>/dev/null || true)"
  if [[ "$python_found" == false && -n "$uv_cmd" ]]; then
    info "未发现可用的系统 Python，正在通过 uv 准备环境..."
    # 尝试寻找或安装
    if ! "$uv_cmd" python find "$python_constraint" &>/dev/null; then
      info "uv 尚未安装满足 ${python_constraint} 的 Python，正在自动下载..."
      "$uv_cmd" python install "${python_candidates[0]}" >&2 || true
    fi
    
    if "$uv_cmd" python find "$python_constraint" &>/dev/null; then
      PYTHON_CMD=$("$uv_cmd" python find "$python_constraint" | head -n1)
      if [[ "$ENGINE" == "vllm-metal" ]]; then
        if ! python_is_arm64 "$PYTHON_CMD"; then
          PYTHON_CMD=""
          python_found=false
        elif [[ "$(python_version_major_minor "$PYTHON_CMD")" != "$required_major_minor" ]]; then
          PYTHON_CMD=""
          python_found=false
        else
          python_found=true
          success "使用 uv 提供的 Python: $PYTHON_CMD"
        fi
      else
        python_found=true
        success "使用 uv 提供的 Python: $PYTHON_CMD"
      fi
    fi
  fi

  # 3. 尝试 pyenv
  local pyenv_cmd=""
  pyenv_cmd="$(find_cmd pyenv 2>/dev/null || true)"
  if [[ "$python_found" == false && -n "$pyenv_cmd" ]]; then
    info "正在通过 pyenv 查找 Python..."
    local pyenv_pattern="^3\\.(10|11|12)"
    [[ "$ENGINE" == "vllm-metal" ]] && pyenv_pattern="^3\\.12(\\.|$)"
    local pyenv_ver=$("$pyenv_cmd" versions --bare | grep -E "$pyenv_pattern" | tail -n1 || echo "")
    if [[ -n "$pyenv_ver" ]]; then
       PYTHON_CMD=$("$pyenv_cmd" prefix "$pyenv_ver")/bin/python
       if [[ "$ENGINE" == "vllm-metal" ]]; then
         if python_is_arm64 "$PYTHON_CMD" && [[ "$(python_version_major_minor "$PYTHON_CMD")" == "$required_major_minor" ]]; then
           python_found=true
           success "使用 pyenv 提供的 Python: $PYTHON_CMD"
         else
           PYTHON_CMD=""
         fi
       else
         python_found=true
         success "使用 pyenv 提供的 Python: $PYTHON_CMD"
       fi
    fi
  fi

  # 4. 通用兜底：覆盖 SSH 非登录 shell 缺少 /opt/homebrew/bin 或 ~/.local/bin 的情况
  if [[ "$python_found" == false ]]; then
    for ver in "${python_candidates[@]}"; do
        local cmd="python${ver}"
        if PYTHON_CMD="$(find_cmd "$cmd" 2>/dev/null)"; then
          if [[ "$ENGINE" == "vllm-metal" ]]; then
            if ! python_is_arm64 "$PYTHON_CMD"; then
              continue
            fi
            if [[ "$(python_version_major_minor "$PYTHON_CMD")" != "$required_major_minor" ]]; then
              continue
            fi
          fi
          python_found=true
          break
        fi
    done
  fi

  if [[ "$python_found" == false ]]; then
    if [[ "$OS" == "macos" ]]; then
      warn "系统缺失必要的编译环境或 Python 管理器 (uv/pyenv)。"
      info "正在请求安装 Xcode 命令行工具，请在弹出的窗口中确认..."
      xcode-select --install || true
      info "💡 建议: 您也可以安装 uv (推荐) 来绕过 Xcode 限制: https://astral.sh/uv"
      error "环境不完整，请安装 Xcode、uv 或 Python ${min_python_version}+ 后重试。"
      exit 1
    fi
    warn "未找到合适的 Python 3.9+ 环境，准备尝试通过系统包管理器安装..."
    install_python
    check_python
    return
  fi
  
  PYTHON_PATH="$PYTHON_CMD"
  PYTHON_VER=$("$PYTHON_CMD" --version 2>&1 | grep "Python" | awk '{print $2}' || echo "Unknown")
  if ! "$PYTHON_CMD" - "$min_python_version" <<'PY' >/dev/null 2>&1; then
import sys
need = tuple(map(int, sys.argv[1].split(".")))
cur = tuple(map(int, sys.version_info[:2]))
sys.exit(0 if cur >= need else 1)
PY
    error "${ENGINE} 需要 Python >= ${min_python_version}，当前为 ${PYTHON_VER} (${PYTHON_PATH})"
    if [[ "$ENGINE" == "vllm-metal" ]]; then
      info "建议安装: brew install python@3.12  或  uv python install 3.12"
    fi
    exit 1
  fi
  success "最终确定 Python ${PYTHON_VER}: ${PYTHON_PATH}"
  
  # 检查并修复 pip
  if ! "$PYTHON_CMD" -m pip --version &>/dev/null; then
    warn "pip 未安装，正在尝试修复..."
    "$PYTHON_CMD" -m ensurepip --default-pip &>/dev/null || \
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$PYTHON_CMD" - || true
  fi
}

install_python() {
  local target_os="${OS:-macos}"
  info "正在通过系统包管理器安装 Python..."
  
  case "$target_os" in
    macos)
      # 寻找 brew 路径
      local brew_bin=""
      if [[ -f "/opt/homebrew/bin/brew" ]]; then
        brew_bin="/opt/homebrew/bin/brew"
      elif [[ -f "/usr/local/bin/brew" ]]; then
        brew_bin="/usr/local/bin/brew"
      elif command -v brew &>/dev/null; then
        brew_bin=$(command -v brew)
      fi

      if [[ -z "$brew_bin" ]]; then
        info "未检测到 Homebrew，正在安装..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
          error "Homebrew 安装失败，请手动安装 Python 3.9+"
          exit 1
        }
        # 再次尝试寻找
        if [[ -f "/opt/homebrew/bin/brew" ]]; then
          brew_bin="/opt/homebrew/bin/brew"
        elif [[ -f "/usr/local/bin/brew" ]]; then
          brew_bin="/usr/local/bin/brew"
        else
          error "Homebrew 安装后依然无法找到执行路径，请手动安装 Python"
          exit 1
        fi
      fi

      info "执行 brew install python..."
      "$brew_bin" install python || {
        error "brew 安装 Python 失败"
        exit 1
      }
      ;;
    linux)
      case "$DISTRO" in
        ubuntu|debian)
          sudo apt-get update
          sudo apt-get install -y python3 python3-pip python3-venv
          ;;
        centos|rhel|rocky|almalinux)
          sudo dnf install -y python3 python3-pip || sudo yum install -y python3 python3-pip
          ;;
        *)
          error "不支持的发行版: ${DISTRO}，请手动安装 Python 3.9+"
          exit 1
          ;;
      esac
      ;;
  esac
}

install_dependencies() {
  info "安装系统依赖..."
  if [[ ! -t 0 && "${VLLM_INSTALL_SYSTEM_DEPS:-0}" != "1" ]]; then
    warn "非交互模式默认不安装系统依赖；如需自动安装，请设置 VLLM_INSTALL_SYSTEM_DEPS=1。"
    return 0
  fi
  case "$OS" in
    macos)
      # 寻找 brew 路径 (Apple Silicon 或 Intel)
      local brew_bin=""
      if [[ -f "/opt/homebrew/bin/brew" ]]; then
        brew_bin="/opt/homebrew/bin/brew"
      elif [[ -f "/usr/local/bin/brew" ]]; then
        brew_bin="/usr/local/bin/brew"
      elif command -v brew &>/dev/null; then
        brew_bin=$(command -v brew)
      fi

      if [[ -n "$brew_bin" ]]; then
        export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
        for pkg in cmake rust; do
          if "$brew_bin" list --versions "$pkg" >/dev/null 2>&1; then
            info "Homebrew 依赖已安装: ${pkg}"
          else
            "$brew_bin" install "$pkg" || true
          fi
        done
        # vllm-metal 需要 maturin (Rust/Python 构建工具)
        if [[ "$ENGINE" == "vllm-metal" ]]; then
          if "$brew_bin" list --versions maturin >/dev/null 2>&1; then
            info "Homebrew 依赖已安装: maturin"
          else
            "$brew_bin" install maturin || true
          fi
        fi
      else
        warn "未检测到 Homebrew，建议安装以补全编译依赖: https://brew.sh/"
      fi
      ;;
    linux)
      case "$DISTRO" in
        ubuntu|debian)
          sudo apt-get update
          sudo apt-get install -y build-essential cmake rustc || true
          ;;
        centos|rhel|rocky|almalinux)
          sudo dnf groupinstall -y "Development Tools" || true
          sudo dnf install -y cmake rust || true
          ;;
      esac
      ;;
  esac
}

# --------------------------- vLLM 安装 ---------------------------------------
create_directories() {
  mkdir -p "${INSTALL_DIR}" "${MODEL_DIR}"
  info "创建目录: ${INSTALL_DIR}"
}

sync_official_metal_venv() {
  [[ "$ENGINE" == "vllm-metal" ]] || return 0
  [[ -d "$HOME/.venv-vllm-metal" ]] || return 0
  [[ -f "$HOME/.venv-vllm-metal/bin/activate" ]] || return 0
  if [[ -e "${VENV_DIR}" && ! -L "${VENV_DIR}" ]]; then
    return 0
  fi
  mkdir -p "${INSTALL_DIR}"
  ln -sfn "$HOME/.venv-vllm-metal" "${VENV_DIR}"
}

create_venv() {
  sync_official_metal_venv
  if [[ -d "${VENV_DIR}" ]] && [[ -f "${VENV_DIR}/bin/activate" ]]; then
    info "虚拟环境已存在: ${VENV_DIR}"
  else
    info "创建 Python 虚拟环境..."
    local uv_cmd=""
    uv_cmd="$(find_cmd uv 2>/dev/null || true)"
    if [[ -n "$uv_cmd" ]]; then
      info "检测到 uv，使用 uv 极速创建环境..."
      "$uv_cmd" venv "${VENV_DIR}" --python "$PYTHON_CMD"
    else
      "$PYTHON_CMD" -m venv "${VENV_DIR}"
    fi
  fi
  
  # 激活虚拟环境
  source "${VENV_DIR}/bin/activate"
  
  # 升级基础组件
  local uv_cmd=""
  uv_cmd="$(find_cmd uv 2>/dev/null || true)"
  if [[ -n "$uv_cmd" ]]; then
    "$uv_cmd" pip install --python "${VENV_DIR}/bin/python" --upgrade pip setuptools wheel
  else
    pip install --upgrade pip setuptools wheel
  fi
  success "虚拟环境就绪"
}

python_satisfies_min() {
  local python_bin="$1" min_version="$2"
  "$python_bin" - "$min_version" <<'PY' >/dev/null 2>&1
import sys
need = tuple(map(int, sys.argv[1].split(".")[:2]))
cur = tuple(map(int, sys.version_info[:2]))
sys.exit(0 if cur >= need else 1)
PY
}

backup_current_venv() {
  [[ -z "$LAST_VENV_BACKUP" ]] || return 0
  [[ -e "${VENV_DIR}" || -L "${VENV_DIR}" ]] || return 0
  LAST_VENV_BACKUP="${VENV_DIR}.backup.$(date +%Y%m%d%H%M%S)"
  warn "切换 Python 需要重建虚拟环境，先备份当前 venv: ${LAST_VENV_BACKUP}"
  mv "${VENV_DIR}" "${LAST_VENV_BACKUP}"
}

restore_venv_backup() {
  [[ -n "$LAST_VENV_BACKUP" ]] || return 0
  [[ -e "$LAST_VENV_BACKUP" || -L "$LAST_VENV_BACKUP" ]] || return 0
  warn "恢复升级前的虚拟环境: ${LAST_VENV_BACKUP}"
  rm -rf "${VENV_DIR}"
  mv "${LAST_VENV_BACKUP}" "${VENV_DIR}"
  LAST_VENV_BACKUP=""
  source "${VENV_DIR}/bin/activate"
}

discard_venv_backup() {
  [[ -n "$LAST_VENV_BACKUP" ]] || return 0
  [[ -e "$LAST_VENV_BACKUP" || -L "$LAST_VENV_BACKUP" ]] || { LAST_VENV_BACKUP=""; return 0; }
  info "新版环境安装成功，清理临时 venv 备份: ${LAST_VENV_BACKUP}"
  rm -rf "${LAST_VENV_BACKUP}"
  LAST_VENV_BACKUP=""
}

recreate_venv_with_current_python() {
  backup_current_venv
  info "使用 Python ${PYTHON_VER} 重建虚拟环境..."
  local uv_cmd
  uv_cmd="$(find_cmd uv 2>/dev/null || true)"
  if [[ -n "$uv_cmd" ]]; then
    "$uv_cmd" venv "${VENV_DIR}" --python "$PYTHON_CMD"
  else
    "$PYTHON_CMD" -m venv "${VENV_DIR}"
  fi
  source "${VENV_DIR}/bin/activate"
  if [[ -n "$uv_cmd" ]]; then
    "$uv_cmd" pip install --python "${VENV_DIR}/bin/python" --upgrade pip setuptools wheel
  else
    python -m pip install --upgrade pip setuptools wheel
  fi
}

extract_required_python_min() {
  local log_file="$1"
  grep -Eio '(requires python|requires-python|python)[^0-9]*(>=|=>)[[:space:]]*[0-9]+(\.[0-9]+){1,2}' "$log_file" 2>/dev/null \
    | head -n1 \
    | grep -Eo '[0-9]+(\.[0-9]+){1,2}' \
    | head -n1 || true
}

platform_wheel_incompatible_error() {
  local log_file="$1"
  [[ "$OS" == "macos" && "$ARCH" == "arm64" ]] || return 1
  grep -Eiq 'tokenspeed-mla|no wheels? with a matching platform tag|matching platform tag.*macosx|manylinux_.*(aarch64|x86_64)' "$log_file"
}

ensure_python_for_package_requirement() {
  local min_version="$1"
  [[ -n "$min_version" ]] || return 1
  if python_satisfies_min "$PYTHON_CMD" "$min_version"; then
    return 0
  fi

  local uv_cmd python_constraint
  uv_cmd="$(find_cmd uv 2>/dev/null || true)"
  if [[ -z "$uv_cmd" ]]; then
    warn "依赖要求 Python >= ${min_version}，但未找到 uv，无法自动准备新版 Python。"
    return 1
  fi

  python_constraint=">=${min_version}"
  info "依赖要求 Python >= ${min_version}，优先使用 uv 查找/安装匹配版本..."
  if ! "$uv_cmd" python find "$python_constraint" >/dev/null 2>&1; then
    "$uv_cmd" python install "$min_version" || return 1
  fi

  PYTHON_CMD=$("$uv_cmd" python find "$python_constraint" | head -n1)
  PYTHON_PATH="$PYTHON_CMD"
  PYTHON_VER=$("$PYTHON_CMD" --version 2>&1 | awk '/Python/{print $2; exit}')
  success "切换到 uv Python ${PYTHON_VER}: ${PYTHON_PATH}"
  recreate_venv_with_current_python
}

run_package_install_once() {
  local log_file="$1"; shift
  local uv_cmd output status
  uv_cmd="$(find_cmd uv 2>/dev/null || true)"

  set +e
  if [[ -n "$uv_cmd" && -x "${VENV_DIR}/bin/python" ]]; then
    info "使用 uv 安装: $*"
    output=$("$uv_cmd" pip install --python "${VENV_DIR}/bin/python" "$@" 2>&1)
    status=$?
  else
    info "使用 pip 安装: $*"
    output=$(python -m pip install "$@" 2>&1)
    status=$?
  fi
  set -e

  printf '%s\n' "$output"
  printf '%s\n' "$output" > "$log_file"
  return "$status"
}

install_python_package() {
  local label="$1"; shift
  local log_file status required_python
  log_file=$(mktemp "${TMPDIR:-/tmp}/vllm-install.XXXXXX.log")

  if run_package_install_once "$log_file" "$@"; then
    rm -f "$log_file"
    return 0
  else
    status=$?
  fi

  if platform_wheel_incompatible_error "$log_file"; then
    warn "${label} 在当前 macOS arm64 环境无法解析依赖，通常是上游包缺少 macOS arm64 wheel。"
    warn "本次不会强行安装不可用版本；如已有旧版本，将保留旧版本继续后续配置。"
    rm -f "$log_file"
    return 42
  fi

  required_python="$(extract_required_python_min "$log_file")"
  if [[ -n "$required_python" ]]; then
    if ensure_python_for_package_requirement "$required_python"; then
      info "Python 已切换，重试安装 ${label}..."
      if run_package_install_once "$log_file" "$@"; then
        rm -f "$log_file"
        return 0
      else
        status=$?
      fi
      if platform_wheel_incompatible_error "$log_file"; then
        warn "${label} 仍因平台 wheel 不兼容而无法安装。"
        rm -f "$log_file"
        return 42
      fi
    fi
  fi

  warn "${label} 安装失败，详细输出见: ${log_file}"
  return "$status"
}

# ---------- 引擎: vllm (标准) ----------
install_vllm_engine() {
  info "安装 vLLM (标准版)..."

  local package="vllm"
  [[ -n "$VLLM_VERSION" ]] && package="vllm==${VLLM_VERSION}"

  # 根据平台选择安装版本
  if [[ "$GPU_TYPE" == "cuda" ]]; then
    install_python_package "vLLM" "$package" || return $?
  elif [[ "$GPU_TYPE" == "mps" ]]; then
    info "macOS Apple Silicon 安装 (MPS 加速)"
    install_python_package "vLLM" "$package" || return $?
  elif [[ "$GPU_TYPE" == "rocm" ]]; then
    info "AMD ROCm 安装"
    install_python_package "vLLM" "$package" --index-url https://download.pytorch.org/whl/rocm6.0 || return $?
  else
    warn "CPU 模式 - 推理速度会很慢"
    install_python_package "vLLM" "$package" || return $?
  fi
  
  # 验证安装
  if python -c "import vllm; print(f'vLLM 版本: {vllm.__version__}')" &>/dev/null; then
    success "vLLM 安装成功"
    python -c "import vllm; print(f'vLLM 版本: {vllm.__version__}')"
  else
    error "vLLM 安装或验证失败"
    exit 1
  fi
}

# ---------- 引擎: vllm-mlx ----------
install_vllm_mlx_engine() {
  info "安装 vllm-mlx..."
  echo ""
  info "引擎: vllm-mlx (MLX 后端, Apple Silicon 优化)"
  info "特性: OpenAI+Anthropic API, 多模态, MCP 工具调用, SSD 缓存, 推测解码"
  echo ""

  local package="vllm-mlx"
  if [[ -n "$VLLM_VERSION" ]]; then
    package="vllm-mlx==${VLLM_VERSION}"
  fi
  install_python_package "vllm-mlx" "$package" || return $?

  # 验证安装
  if command -v vllm-mlx &>/dev/null; then
    local ver
    ver=$(vllm-mlx --version 2>/dev/null || python -c "import vllm_mlx; print(vllm_mlx.__version__)" 2>/dev/null || echo "未知")
    success "vllm-mlx 安装成功 (版本: ${ver})"
  elif python -c "import vllm_mlx; print(f'vllm-mlx 版本: {vllm_mlx.__version__}')" &>/dev/null; then
    success "vllm-mlx 安装成功"
  else
    error "vllm-mlx 安装或验证失败"
    exit 1
  fi
}

# ---------- 引擎: vllm-metal ----------
install_vllm_metal_engine() {
  info "安装 vllm-metal (官方 Metal 插件)..."
  echo ""
  info "引擎: vllm-metal (vLLM 官方 Metal+MLX 后端)"
  info "特性: PagedAttention, 持续批处理, Apple Silicon Metal kernel"
  info "安装方式: 官方 release wheel + Python 3.12 arm64"
  echo ""

  if ! is_apple_silicon; then
    error "vllm-metal 仅支持 macOS Apple Silicon"
    return 1
  fi

  if ! python_is_arm64 "$PYTHON_CMD"; then
    error "vllm-metal 需要原生 arm64 Python ${PYTHON_VER}"
    return 1
  fi

  local version_target="${VERSION_PACKAGE_TARGET:-vllm-metal}"
  if [[ "$version_target" == "vllm" ]]; then
    info "当前环境未检测到独立 vllm-metal 包，本次仅更新 vLLM 核心包。"
    local core_package="vllm"
    [[ -n "$VLLM_VERSION" ]] && core_package="vllm==${VLLM_VERSION}"
    install_python_package "VLLM 核心包" "$core_package" || return $?
    success "vLLM 核心包已更新/安装"
    return 0
  fi

  local uv_cmd
  uv_cmd="$(find_cmd uv 2>/dev/null || true)"
  if [[ -z "$uv_cmd" ]]; then
    warn "未找到 uv, 正在安装..."
    curl -fsSL https://astral.sh/uv/install.sh | sh 2>/dev/null || {
      error "uv 安装失败, vllm-metal 需要 uv 来管理依赖"
      return 1
    }
    uv_cmd="$(find_cmd uv 2>/dev/null || true)"
    [[ -n "$uv_cmd" ]] || { error "uv 安装后仍不可用"; return 1; }
  fi

  local tmp_json tmp_wheel_dir tmp_wheel wheel_url wheel_name
  tmp_json=$(mktemp "${TMPDIR:-/tmp}/vllm-metal-release.XXXXXX.json")
  tmp_wheel_dir=$(mktemp -d "${TMPDIR:-/tmp}/vllm-metal-wheel.XXXXXX")
  # 注意: RETURN trap 在 bash 中不会随函数返回自动清除，必须在触发后自行 trap - RETURN，
  # 否则后续任意函数返回时会再次触发并因 set -u 访问已失效的局部变量而中断。
  trap 'rm -f "${tmp_json:-}" 2>/dev/null; rm -rf "${tmp_wheel_dir:-}" 2>/dev/null; trap - RETURN' RETURN

  if ! fetch_release_json "https://api.github.com/repos/vllm-project/vllm-metal/releases/latest" "$tmp_json"; then
    error "无法获取 vllm-metal release 信息"
    return 1
  fi

  wheel_url="$(extract_release_asset_url "$tmp_json" '\.whl$')"
  if [[ -z "$wheel_url" ]]; then
    error "vllm-metal release 中未找到 wheel"
    return 1
  fi
  wheel_name="$(basename "${wheel_url%%\?*}")"
  # 必须使用 release 中真实的 wheel 文件名 (含 ABI tag)，否则 uv/pip 解析文件名失败:
  #   "The wheel filename ... is invalid: Must have an ABI tag"
  tmp_wheel="${tmp_wheel_dir}/${wheel_name}"

  info "下载 vllm-metal wheel: ${wheel_name}"
  # 优先用 adl (支持代理/断点续传)，回退到 curl。
  # 不再静默 stderr，下载失败时把真实原因暴露给用户，便于排查网络/代理问题。
  local dl_ok=false
  if command -v adl >/dev/null 2>&1; then
    if adl "$wheel_url" "$tmp_wheel_dir" "$wheel_name"; then
      dl_ok=true
    else
      warn "adl 下载失败，回退到 curl..."
    fi
  fi
  if [[ "$dl_ok" != "true" ]] && curl -fSL "$wheel_url" -o "$tmp_wheel"; then
    dl_ok=true
  fi
  if [[ "$dl_ok" != "true" ]] || [[ ! -s "$tmp_wheel" ]]; then
    error "vllm-metal wheel 下载失败: ${wheel_url}"
    error "请检查网络/代理后重试；或手动下载该 wheel 后执行:"
    error "  ${uv_cmd} pip install --python ${VENV_DIR}/bin/python <wheel 文件路径>"
    return 1
  fi

  # vLLM 核心包在 macOS arm64 上没有预编译 wheel，必须先从官方源码 tarball 编译安装，
  # 否则安装 vllm-metal wheel 时 resolver 解析 vllm 依赖会失败（缺少平台 wheel）。
  # 该步骤对齐官方 vllm-metal/install.sh 的处理方式。
  if ! venv_has_module "${VENV_DIR}" "vllm"; then
    local vllm_core_ver="${VLLM_METAL_CORE_VERSION:-0.22.1}"
    local vllm_tarball="vllm-${vllm_core_ver}.tar.gz"
    local vllm_url="https://github.com/vllm-project/vllm/releases/download/v${vllm_core_ver}/${vllm_tarball}"
    local vllm_tmp_dir vllm_src_dir
    vllm_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/vllm-core.XXXXXX")
    vllm_src_dir="${vllm_tmp_dir}/vllm-${vllm_core_ver}"

    info "从源码编译安装 vLLM 核心包 v${vllm_core_ver} (macOS arm64 无预编译 wheel)..."
    local core_dl_ok=false
    if command -v adl >/dev/null 2>&1; then
      adl "$vllm_url" "$vllm_tmp_dir" "$vllm_tarball" && core_dl_ok=true
    fi
    if [[ "$core_dl_ok" != "true" ]] && curl -fSL "$vllm_url" -o "${vllm_tmp_dir}/${vllm_tarball}"; then
      core_dl_ok=true
    fi
    if [[ "$core_dl_ok" != "true" ]] || [[ ! -s "${vllm_tmp_dir}/${vllm_tarball}" ]]; then
      error "vLLM 核心包源码下载失败: ${vllm_url}"
      rm -rf "$vllm_tmp_dir"
      return 1
    fi

    if ! tar xf "${vllm_tmp_dir}/${vllm_tarball}" -C "$vllm_tmp_dir"; then
      error "vLLM 核心包源码解压失败"
      rm -rf "$vllm_tmp_dir"
      return 1
    fi

    if ! ( cd "$vllm_src_dir" \
           && "$uv_cmd" pip install --python "${VENV_DIR}/bin/python" -r requirements/cpu.txt --index-strategy unsafe-best-match \
           && CXXFLAGS="-Wno-parentheses" "$uv_cmd" pip install --python "${VENV_DIR}/bin/python" . ); then
      error "vLLM 核心包编译安装失败 (源码: ${vllm_src_dir})"
      rm -rf "$vllm_tmp_dir"
      return 1
    fi
    rm -rf "$vllm_tmp_dir"
    success "vLLM 核心包 v${vllm_core_ver} 编译安装完成"
  fi

  if ! "$uv_cmd" pip install --python "${VENV_DIR}/bin/python" "$tmp_wheel"; then
    error "vllm-metal wheel 安装失败"
    return 1
  fi

  if python -c "import vllm; print(f'vLLM 版本: {vllm.__version__}')" &>/dev/null; then
    python -c "import vllm; print(f'vLLM 版本: {vllm.__version__}')"
    # vllm-metal 通过 entry point 'vllm.platform_plugins' 注册插件 (metal -> vllm_metal:register)，
    # 并不存在 'vllm.platform_plugins' 这个 Python 模块，旧的 import 检测必然失败。
    # 正确判断: vllm_metal 包可导入 且 entry point 已注册。
    if python - <<'PY' 2>/dev/null; then
import importlib.util
import importlib.metadata as metadata
import sys
mod_ok = importlib.util.find_spec("vllm_metal") is not None
ep_ok = any(ep.name == "metal" for ep in metadata.entry_points(group="vllm.platform_plugins"))
sys.exit(0 if (mod_ok and ep_ok) else 1)
PY
      success "vllm-metal 已安装且 Metal 插件已注册"
    else
      error "Metal 插件未注册 (vllm_metal 包或 entry point 缺失)"
      return 1
    fi
  else
    error "vllm-metal 安装或验证失败"
    return 1
  fi
}
# ---------- 引擎分发 ----------
install_engine() {
  case "$ENGINE" in
    vllm)       install_vllm_engine ;;
    vllm-mlx)   install_vllm_mlx_engine ;;
    vllm-metal) install_vllm_metal_engine ;;
  esac
}

# 获取引擎的启动命令前缀
engine_serve_command() {
  case "$ENGINE" in
    vllm)       echo "python -m vllm.entrypoints.openai.api_server" ;;
    vllm-mlx)   echo "vllm-mlx serve" ;;
    vllm-metal) echo "vllm serve" ;;
  esac
}

# 获取引擎的 Python 模块名 (用于版本检测)
engine_python_module() {
  case "$ENGINE" in
    vllm)       echo "vllm" ;;
    vllm-mlx)   echo "vllm_mlx" ;;
    vllm-metal) echo "vllm" ;;  # vllm-metal 是 vLLM 的插件, 模块名仍为 vllm
  esac
}

# 获取引擎的 PyPI 包名
engine_pypi_package() {
  case "$ENGINE" in
    vllm)       echo "vllm" ;;
    vllm-mlx)   echo "vllm-mlx" ;;
    vllm-metal) echo "vllm-metal" ;;
  esac
}

# 检查本地是否开启了科学上网代理 (例如 Clash/V2Ray 默认的 7890)
detect_proxy() {
  if curl -s --connect-timeout 2 -x http://127.0.0.1:7890 https://huggingface.co > /dev/null 2>&1; then
    echo "http://127.0.0.1:7890"
  else
    echo ""
  fi
}

ds4_server_running() {
  pgrep -f "ds4-server" >/dev/null 2>&1
}

download_model() {
  local model_name="${1:-$DEFAULT_MODEL}"
  model_name=$(resolve_model_alias "$model_name")

  # ---- vllm-metal 引擎: 自动转换为 MLX 格式模型 ----
  # vllm-metal 基于 MLX 框架，需要 mlx-community 组织下的 4bit 量化模型
  # 标准 HF 模型 (如 Qwen/Qwen3.6-27B) 需转换为 MLX 格式 (如 mlx-community/Qwen3.6-27B-4bit)
  if [[ "$ENGINE" == "vllm-metal" ]]; then
    local mlx_model
    mlx_model=$(to_mlx_model_name "$model_name")
    if [[ "$mlx_model" != "$model_name" ]]; then
      info "vllm-metal 引擎: 自动转换模型名称"
      info "  标准: ${model_name}"
      info "  MLX:  ${mlx_model}"
      model_name="$mlx_model"
    fi
  fi

  local model_dir
  model_dir=$(model_local_dir "$model_name")

  info "检查模型: ${model_name}"

  # 检查模型是否已下载
  if [[ -d "${model_dir}" ]]; then
    if model_dir_complete "${model_dir}"; then
      success "模型已存在: ${model_dir}"
      return
    elif [[ -n "$(ls -A "${model_dir}" 2>/dev/null)" ]]; then
      warn "模型目录不完整，未发现权重文件 (*.safetensors/*.bin/*.gguf): ${model_dir}"
      warn "将继续下载缺失权重。"
    fi
  fi

  # ---- 下载后端优先级: adl --repo > modelscope > hf ----

  # 1. adl --repo 后端 (断点续传 + 并行下载)。adl 自己负责探测 aria2c/代理。
  local adl_path="${ADL_PATH:-${SCRIPT_DIR}/../../../network/tools/adl}"
  if [[ -f "$adl_path" ]] && [[ -x "$adl_path" ]]; then
    info "检测到 adl，优先使用 adl --repo 批量下载模型..."
    mkdir -p "${model_dir}"
    if "$adl_path" --repo "${model_name}" -o "${model_dir}" ${ADL_PROGRESS:+--progress}; then
      if model_dir_complete "${model_dir}"; then
        success "模型已通过 adl --repo 下载到: ${model_dir}"
        return 0
      fi
      warn "adl --repo 完成但模型目录不完整，尝试下一后端..."
    else
      warn "adl --repo 下载失败，尝试下一后端..."
    fi
  fi

  # 2. ModelScope 后端 (国内备选: 阿里 CDN，无需代理)
  if curl -sf --connect-timeout 3 "https://modelscope.cn/api/v1/models/${model_name}" >/dev/null 2>&1; then
    info "检测到 ModelScope 可用，尝试 ModelScope 下载..."
    if ! python3 -c "import modelscope" 2>/dev/null; then
      pip install -U modelscope -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com >/dev/null 2>&1 || true
    fi
    if python3 -c "import modelscope" 2>/dev/null; then
      mkdir -p "${model_dir}"
      if modelscope download --model "${model_name}" --local_dir "${model_dir}"; then
        if model_dir_complete "${model_dir}"; then
          success "模型已通过 ModelScope 下载到: ${model_dir}"
          return 0
        fi
        warn "ModelScope 下载完成但模型目录不完整，尝试下一后端..."
      else
        warn "ModelScope 下载失败，尝试下一后端..."
      fi
    fi
  fi

  # 3. hf / huggingface-cli 后端 (需代理或镜像)
  # 自动安装 hf (如果缺失)
  if ! command -v hf &>/dev/null; then
    info "检测到缺失 'hf' 下载引擎，正在尝试通过系统脚本补全..."
    local hf_installer="${SCRIPT_DIR}/install-hf.sh"
    if [[ -f "$hf_installer" ]]; then
      bash "$hf_installer"
    else
      warn "未找到 hf 安装脚本，尝试通过 pip 补全..."
      pip install -U "huggingface_hub[cli]" >/dev/null 2>&1 || true
    fi
  fi

  info "下载模型 ${model_name} (可能需要较长时间)..."

  # 智能网络探测
  local proxy_url
  proxy_url=$(detect_proxy)
  local use_mirror=false
  local cmd_env=()

  if [[ -n "$proxy_url" ]]; then
    info "检测到本地代理可用 ($proxy_url)，将使用代理直连 HuggingFace。"
    cmd_env=(HTTPS_PROXY="$proxy_url" HTTP_PROXY="$proxy_url")
  else
    info "未检测到可用代理，将尝试使用国内镜像站加速 (hf-mirror.com)..."
    use_mirror=true
  fi

  # 下载重试逻辑
  local attempt=1
  local max_attempts=2

  while [[ $attempt -le $max_attempts ]]; do
    if [[ "$use_mirror" == "true" ]]; then
      cmd_env=(HF_ENDPOINT=https://hf-mirror.com)
    fi
    if [[ $attempt -gt 1 && "${VLLM_HF_DISABLE_XET_ON_RETRY:-1}" == "1" ]]; then
      cmd_env+=(HF_HUB_DISABLE_XET=1)
      info "重试下载时禁用 hf-xet，以规避大文件临时签名 URL 过期/403 问题。"
    fi

    local download_success=false
    if command -v hf &>/dev/null; then
        info "使用 'hf' 引擎下载 (尝试 $attempt)..."
        if env "${cmd_env[@]}" hf download "${model_name}" --local-dir "${model_dir}"; then
          download_success=true
        fi
    else
        info "使用 legacy 模式下载 (尝试 $attempt)..."
        if env "${cmd_env[@]}" huggingface-cli download "${model_name}" --local-dir "${model_dir}"; then
          download_success=true
        fi
    fi

    if [[ "$download_success" == "true" ]]; then
      if model_dir_complete "${model_dir}"; then
        success "模型已成功下载到: ${model_dir}"
        return 0
      fi
      warn "下载命令返回成功，但模型目录仍缺少权重文件 (*.safetensors/*.bin/*.gguf)。"
      warn "可能是上次部分下载残留、网络镜像未同步完整，或模型需要授权。"
    fi

    # 失败处理
    warn "下载尝试 $attempt 失败。"
    if [[ -n "$proxy_url" && "$use_mirror" == "false" ]]; then
      warn "代理直连失败，尝试切换到国内镜像站..."
      use_mirror=true
      attempt=$((attempt + 1))
    elif [[ "$use_mirror" == "true" && -z "$proxy_url" && $attempt -eq 1 ]]; then
      warn "镜像站下载失败，再试一次..."
      attempt=$((attempt + 1))
    else
      break
    fi
  done

  error "下载彻底失败。"
  warn "可能原因："
  warn "1. 网络波动或镜像站暂时不可用"
  warn "2. 某些模型（如 Llama-3）需要授权，请运行 'hf auth login' 登录"
  warn "3. 您也可以尝试手动下载模型并放入: ${model_dir}"
  warn "4. 可设置环境变量 ADL_PATH 使用自定义下载工具: export ADL_PATH=/path/to/adl"
  return 1
}

default_model_available() {
  local model_name="${1:-$DEFAULT_MODEL}"
  if [[ "$model_name" == /* || "$model_name" == ./* || "$model_name" == ../* ]]; then
    model_dir_complete "$model_name"
    return $?
  fi

  model_name=$(resolve_model_alias "$model_name")
  model_dir_complete "$(model_local_dir "$model_name")"
}

ensure_default_model() {
  if default_model_available "$DEFAULT_MODEL"; then
    DEFAULT_MODEL="$(model_runtime_ref "$DEFAULT_MODEL")"
    success "默认模型已就绪: ${DEFAULT_MODEL}"
    return 0
  fi

  warn "未检测到可用模型: ${DEFAULT_MODEL}"
  info "将显示模型列表，请选择要下载并部署的模型。"
  run_model_download_wizard

  if ! default_model_available "$DEFAULT_MODEL"; then
    warn "仍未检测到本地模型权重，将使用运行时引用: ${DEFAULT_MODEL}"
  fi
}

model_memory_gb() {
  local name="$1"
  if [[ "$name" == "$MODEL_DIR"/* ]]; then
    local base="${name##*/}"
    local hf_name="${base//_//}"
    name="$hf_name"
  fi
  local row
  row=$(model_catalog | awk -F'|' -v key="$name" '$1 == key || $2 == key {print; exit}')
  [[ -n "$row" ]] && echo "$row" | awk -F'|' '{print $4}' || echo "0"
}

api_wait_seconds() {
  local mem
  mem=$(model_memory_gb "$DEFAULT_MODEL")
  [[ "$mem" =~ ^[0-9]+$ ]] || mem=0

  # vllm-metal 冷启动很慢: 模型加载 + KV cache 分配 + Metal kernel warm-up，
  # 27B(~54GB) 实测仅引擎初始化就 ~44s，叠加首次读盘/编译常超过 120s，需放宽超时。
  if [[ "$ENGINE" == "vllm-metal" ]]; then
    if (( mem >= 60 )); then
      echo "${VLLM_API_WAIT_SECONDS:-420}"
    elif (( mem >= 30 )); then
      echo "${VLLM_API_WAIT_SECONDS:-300}"
    else
      echo "${VLLM_API_WAIT_SECONDS:-180}"
    fi
    return
  fi

  if (( mem >= 60 )); then
    echo "${VLLM_API_WAIT_SECONDS:-180}"
  elif (( mem >= 30 )); then
    echo "${VLLM_API_WAIT_SECONDS:-120}"
  else
    echo "${VLLM_API_WAIT_SECONDS:-60}"
  fi
}

model_recommend_budget_gb() {
  local budget_gb="$TOTAL_MEM_GB"
  if [[ "$GPU_TYPE" == "mps" ]]; then
    budget_gb=$(( TOTAL_MEM_GB * 85 / 100 ))
  elif [[ "$GPU_TYPE" == "cuda" ]]; then
    budget_gb=$(( GPU_MEMORY_GB * 90 / 100 ))
  elif [[ "$GPU_TYPE" == "cpu" ]]; then
    budget_gb=$(( TOTAL_MEM_GB * 60 / 100 ))
  fi
  (( budget_gb < 4 )) && budget_gb=4
  echo "$budget_gb"
}

model_download_recommend_defaults() {
  # 单选策略：根据可用内存预算挑 1 个最匹配模型
  if [[ -n "${WHICHLLM_PRIMARY_CHOICE:-}" ]]; then
    echo "${WHICHLLM_PRIMARY_CHOICE}"
    return 0
  fi

  local budget_gb
  budget_gb=$(model_recommend_budget_gb)

  local pick=""
  if   (( budget_gb >= 70 )); then pick=2     # qwen3.6-35b-a3b (~70GB)
  elif (( budget_gb >= 54 )); then pick=1     # qwen3.6-27b (~54GB)
  elif (( budget_gb >= 32 )); then pick=5     # qwen3-14b (~32GB)
  elif (( budget_gb >= 18 )); then pick=6     # qwen3-8b (~18GB)
  else pick=6
  fi
  echo "$pick"
}

model_choice_for_alias() {
  case "$1" in
    qwen3.6-27b) echo 1 ;;
    qwen3.6-35b-a3b) echo 2 ;;
    qwen3-coder-30b-a3b) echo 3 ;;
    qwen2.5-coder-32b) echo 4 ;;
    qwen3-14b) echo 5 ;;
    qwen3-8b) echo 6 ;;
    deepseek-r1-distill-qwen-32b) echo 7 ;;
    deepseek-r1-distill-qwen-14b) echo 8 ;;
    qwen3-30b-a3b) echo 9 ;;
    glm-4.6) echo 10 ;;
    gemma3-27b) echo 11 ;;
    mistral-small) echo 12 ;;
    deepseek-v4-flash) echo 13 ;;
    llama3.1-8b) echo 14 ;;
    llama3.1-70b) echo 15 ;;
    llama4-scout) echo 16 ;;
    llama4-maverick) echo 17 ;;
    *) return 1 ;;
  esac
}

load_whichllm_recommendations() {
  if [[ ! -x "${WHICHLLM_SCRIPT}" && ! -f "${WHICHLLM_SCRIPT}" ]]; then
    warn "未找到 whichllm 脚本: ${WHICHLLM_SCRIPT}"
    return 0
  fi

  local whichllm_shell=""
  if whichllm_shell="$("${WHICHLLM_SCRIPT}" --engine "${ENGINE}" --format shell 2>/dev/null)"; then
    if [[ -n "${whichllm_shell}" ]]; then
      eval "${whichllm_shell}"
      WHICHLLM_PRIMARY_CHOICE="$(model_choice_for_alias "${WHICHLLM_PRIMARY_ALIAS}" 2>/dev/null || true)"
      if [[ -n "${WHICHLLM_PRIMARY_ALIAS:-}" && "${MODEL_USER_SET}" != "true" ]]; then
        DEFAULT_MODEL="${WHICHLLM_PRIMARY_ALIAS}"
        local catalog_len
        catalog_len=$(model_default_max_len "${DEFAULT_MODEL}")
        [[ -n "${catalog_len}" ]] && DEFAULT_MAX_MODEL_LEN="${catalog_len}"
      fi
    fi
  else
    warn "whichllm 执行失败，继续使用 install_vllm.sh 内置推荐逻辑。"
  fi
}

print_whichllm_summary() {
  [[ -n "${WHICHLLM_PRIMARY_ALIAS:-}" ]] || return 0

  info "whichllm 推荐: 默认 ${WHICHLLM_PRIMARY_ALIAS}，编码 ${WHICHLLM_CODING_ALIAS}，推理 ${WHICHLLM_REASONING_ALIAS}，文档 ${WHICHLLM_DOCS_ALIAS}，轻量 ${WHICHLLM_LIGHT_ALIAS}"
  if [[ -n "${WHICHLLM_TOTAL_MEM_GB:-}" && -n "${WHICHLLM_AVAILABLE_MEM_GB:-}" && -n "${WHICHLLM_BUDGET_GB:-}" ]]; then
    info "whichllm 预算: 总内存 ${WHICHLLM_TOTAL_MEM_GB}GB，可用约 ${WHICHLLM_AVAILABLE_MEM_GB}GB，新增模型预算约 ${WHICHLLM_BUDGET_GB}GB (${WHICHLLM_GPU_TYPE})"
  fi
  if [[ -n "${WHICHLLM_DEEPSEEK_ALIAS:-}" ]]; then
    info "DeepSeek 路径: ${WHICHLLM_DEEPSEEK_ALIAS}（本机优先 DS4，vLLM 视作实验部署）"
  fi
  if [[ "${WHICHLLM_DS4_RUNNING:-false}" == "true" ]]; then
    info "已检测到 ds4-server；是否停服务不作为硬限制，优先看当前可用内存。"
  fi
}

is_recommended_choice() {
  local choice="$1"
  local defaults=" ${2:-} "
  [[ "$defaults" == *" ${choice} "* ]]
}

print_model_download_option() {
  local idx="$1"
  local alias="$2"
  local scene="$3"
  local defaults="$4"
  local mark="  "
  is_recommended_choice "$idx" "$defaults" && mark="★ "
  printf "  %s%2s) %-34s %-10s %s\n" "$mark" "$idx" "$alias" "~$(model_memory_gb "$alias")GB" "$scene"
}

normalize_model_choices() {
  local input="$1"
  local defaults="$2"
  input="${input//,/ }"
  input="${input//，/ }"
  input="${input:-$defaults}"
  printf '%s\n' "$input" | tr ' ' '\n' | awk 'NF && !seen[$1]++ {print $1}'
}

model_alias_for_choice() {
  case "$1" in
    16) echo "qwen3.6-27b" ;;
    17) echo "qwen3.6-35b-a3b" ;;
    1) echo "qwen3-coder-30b-a3b" ;;
    2) echo "qwen2.5-coder-32b" ;;
    3) echo "deepseek-r1-distill-qwen-32b" ;;
    4) echo "qwen3-14b" ;;
    5) echo "qwen3-30b-a3b" ;;
    6) echo "glm-4.6" ;;
    7) echo "gemma3-27b" ;;
    8) echo "mistral-small" ;;
    9) echo "qwen3-8b" ;;
    10) echo "deepseek-r1-distill-qwen-14b" ;;
    11) echo "deepseek-v4-flash" ;;
    12) echo "llama3.1-8b" ;;
    13) echo "llama3.1-70b" ;;
    14) echo "llama4-scout" ;;
    15) echo "llama4-maverick" ;;
    *) return 1 ;;
  esac
}

run_model_download_wizard() {
  echo ""
  info "模型下载向导  (★ = 推荐, 回车=用推荐, 0=跳过, 多个用空格: 1 3 5)"
  echo ""

  local defaults
  defaults=$(model_download_recommend_defaults)

  echo -e "  ${GREEN}[编码优先]${NC}"
  print_model_download_option 1  "qwen3.6-27b"                  "★ 编码+文档主力 (Dense 27B, SWE-bench 77.2%)" "$defaults"
  print_model_download_option 2  "qwen3.6-35b-a3b"               "高速编码 (MoE 3B active, 速度3-4x)" "$defaults"
  print_model_download_option 3  "qwen3-coder-30b-a3b"          "编码 MoE 备选" "$defaults"
  print_model_download_option 4  "qwen2.5-coder-32b"            "编码稳妥备选" "$defaults"
  print_model_download_option 5  "qwen3-14b"                    "轻量编码/可与DS4共存" "$defaults"
  print_model_download_option 6  "qwen3-8b"                     "轻量常驻/快速响应" "$defaults"
  echo ""

  echo -e "  ${CYAN}[推理 / 代码审查]${NC}"
  print_model_download_option 7  "deepseek-r1-distill-qwen-32b" "复杂推理/代码审查" "$defaults"
  print_model_download_option 8  "deepseek-r1-distill-qwen-14b" "轻量推理/可与DS4共存" "$defaults"
  echo ""

  echo -e "  ${CYAN}[PRD / 方案 / 画图文本]${NC}"
  print_model_download_option 9  "qwen3-30b-a3b"                "PRD/流程/结构化输出" "$defaults"
  print_model_download_option 10 "glm-4.6"                      "中文方案/Agent任务" "$defaults"
  print_model_download_option 11 "gemma3-27b"                   "多模态/资料理解" "$defaults"
  print_model_download_option 12 "mistral-small"                "英文/代码备选" "$defaults"
  echo ""

  echo -e "  ${YELLOW}[实验 / 授权模型 - 谨慎]${NC}"
  print_model_download_option 13 "deepseek-v4-flash"            "vLLM实验；DeepSeek更推荐DS4" "$defaults"
  print_model_download_option 14 "llama3.1-8b"                  "Llama轻量；需授权" "$defaults"
  print_model_download_option 15 "llama3.1-70b"                 "需量化/大内存/授权" "$defaults"
  print_model_download_option 16 "llama4-scout"                 "MoE；需授权" "$defaults"
  print_model_download_option 17 "llama4-maverick"              "MoE；需授权" "$defaults"
  echo ""

  if [[ "$GPU_TYPE" == "mps" && "$TOTAL_MEM_GB" -ge 128 ]]; then
    if ds4_server_running; then
      warn "检测到 ds4-server 正在运行；如 DS4 未处理请求，通常可以继续启动 vLLM。"
      info "若后续出现长时间加载、Swap 激增或系统卡顿，再考虑停止 DS4。"
    fi
    info "本机内存预算: ~$(model_recommend_budget_gb)GB（推荐挑 1 个，多选会同时下载但运行时只能起 1 个）。"
  fi

  local selected
  if $ASSUME_YES; then
    selected="${VLLM_DEFAULT_MODEL_SELECTION:-$defaults}"
    info "自动确认模式，选择模型: ${selected}。"
  elif [[ -t 0 ]]; then
    read -rp "请选择下载编号 [默认: ${defaults}，0 跳过]: " selected
  else
    selected="${VLLM_DEFAULT_MODEL_SELECTION:-0}"
    info "非交互模式，自动选择: ${selected}。如需自动下载推荐模型，可设置 VLLM_DEFAULT_MODEL_SELECTION=\"${defaults}\"。"
  fi

  if [[ "${selected:-$defaults}" == "0" ]]; then
    info "已跳过模型下载。后续可重新运行脚本选择模型，或执行: ${INSTALL_DIR}/start_model.sh <模型别名或HF模型名> <端口>"
    return 0
  fi

  # ---------- 动态资源评估 ----------
  local choices_list=()
  while read -r line; do
    [[ -n "$line" ]] && choices_list+=("$line")
  done < <(normalize_model_choices "$selected" "$defaults")

  local biggest_alias="" biggest_mem=0 total_dl_gb=0 alias mem
  for c in "${choices_list[@]}"; do
    alias=$(model_alias_for_choice "$c" 2>/dev/null || true)
    [[ -n "$alias" ]] || continue
    mem=$(model_memory_gb "$alias")
    [[ "$mem" =~ ^[0-9]+$ ]] || mem=0
    total_dl_gb=$((total_dl_gb + mem))
    if (( mem > biggest_mem )); then
      biggest_mem=$mem
      biggest_alias=$alias
    fi
  done

  if [[ -n "$biggest_alias" && "$GPU_TYPE" == "mps" ]]; then
    local available_gb runtime_threshold
    available_gb=$(get_available_mem_gb 2>/dev/null || echo "$TOTAL_MEM_GB")
    runtime_threshold=$((biggest_mem * 100 / 80))  # 留 20% 余量
    echo ""
    info "运行时评估: 最大模型 ${biggest_alias} 需 ~${biggest_mem}GB，建议至少 ${runtime_threshold}GB 可用，当前可用 ~${available_gb}GB。"
    if ds4_server_running && (( biggest_mem > 32 )); then
      warn "DS4 正在运行，但当前可用内存评估充足；继续配置 ${biggest_alias}。"
    fi
    if (( available_gb < runtime_threshold )); then
      warn "可用内存不足以稳定运行 ${biggest_alias}。"
      if ds4_server_running; then
        info "建议方案 (任选其一)："
        info "  A) 临时停掉 ds4-server (释放 ~78GB):  pkill ds4-server"
        info "  B) 改选 ~$((available_gb - 4))GB 以内的小模型 (qwen3-8b/14b)"
        info "  C) 继续下载（多模型可保留），但运行时仅起一个轻量模型"
      fi
      warn "仅提示资源风险，不自动干预。若确认空闲内存充足，可继续部署重模型。"
    else
      success "资源评估通过：${biggest_alias} 可在当前环境运行。"
    fi
    if (( ${#choices_list[@]} > 1 )); then
      info "已勾选 ${#choices_list[@]} 个模型，下载总量约 ~${total_dl_gb}GB；运行时只起 1 个，其余作为常驻备选。"
    fi
  fi

  local choices choice alias first_model="" enable_speculative=false speculative_config="" selected_aliases=()
  choices=$(normalize_model_choices "$selected" "$defaults")
  while read -r choice; do
    [[ -n "$choice" ]] || continue
    alias=$(model_alias_for_choice "$choice" || true)
    if [[ -z "$alias" ]]; then
      warn "忽略无效选项: ${choice}"
      continue
    fi
    case "$alias" in
      deepseek-v4-flash)
        warn "DeepSeek-V4-Flash 在 vLLM 中属于实验部署；本机 DeepSeek V4 Flash 更推荐 DS4。"
        ;;
      llama3.1-70b|llama4-scout|llama4-maverick)
        warn "${alias} 通常需要授权或量化，请确认已完成 HuggingFace 授权。"
        ;;
    esac
    [[ -z "$first_model" ]] && first_model="$alias"
    selected_aliases+=("$alias")
    download_model "$alias"
  done <<< "$choices"

  if [[ -n "$first_model" ]]; then
    DEFAULT_MODEL=$(model_runtime_ref "$first_model")
    local catalog_len
    catalog_len=$(model_default_max_len "$first_model")
    [[ -n "$catalog_len" ]] && DEFAULT_MAX_MODEL_LEN="$catalog_len"
    speculative_config=$(model_speculative_config "$first_model")
    [[ -n "$speculative_config" ]] && enable_speculative=true
  fi

  ENABLE_SPECULATIVE="$enable_speculative"
  SPECULATIVE_CONFIG="$speculative_config"

  if [[ "${#selected_aliases[@]}" -gt 0 ]]; then
    info "已选择 ${selected_aliases[*]} → 默认启动: ${DEFAULT_MODEL}"
  fi
}

# --------------------------- 配置文件 ----------------------------------------
generate_config() {
  info "生成配置文件: ${CONFIG_FILE}"
  local runtime_model
  runtime_model=$(model_runtime_ref "$DEFAULT_MODEL")
  DEFAULT_MODEL="$runtime_model"
  
  # 构建投机解码配置行
  local spec_config_line=""
  if [[ "$ENABLE_SPECULATIVE" == "true" ]] && [[ -n "$SPECULATIVE_CONFIG" ]]; then
    spec_config_line="
# 投机解码配置 (Speculative Decoding)
# 可选方法: ngram(轻量), draft_model(需额外模型), mtp(原生MTP支持), eagle3, suffix
VLLM_SPECULATIVE_CONFIG='${SPECULATIVE_CONFIG}'
VLLM_ENABLE_SPECULATIVE=true"
  else
    spec_config_line="
# 投机解码配置 (默认关闭)
# 启用示例: VLLM_SPECULATIVE_CONFIG='{\"method\":\"ngram\",\"num_speculative_tokens\":5}'
# VLLM_ENABLE_SPECULATIVE=true"
  fi

  # 引擎特定配置
  local engine_config=""
  local engine_serve_cmd
  engine_serve_cmd=$(engine_serve_command)

  if [[ "$ENGINE" == "vllm-mlx" ]]; then
    engine_config="
# vllm-mlx 特定配置
VLLM_ENGINE=vllm-mlx
VLLM_SERVE_CMD='${engine_serve_cmd}'
# vllm-mlx 额外参数 (按需启用)
# VLLM_MLX_CONTINUOUS_BATCHING=true
# VLLM_MLX_SSD_CACHE_DIR=/path/to/ssd_cache
# VLLM_MLX_MOE_TOP_K=4
# VLLM_MLX_METRICS=true
# VLLM_MLX_REASONING_PARSER=qwen3"
  elif [[ "$ENGINE" == "vllm-metal" ]]; then
    engine_config="
# vllm-metal 特定配置
VLLM_ENGINE=vllm-metal
VLLM_SERVE_CMD='${engine_serve_cmd}'
# vllm-metal 环境变量 (按需调整)
# PagedAttention: 显著提升 TTFT 和吞吐量 (部分模型可能不兼容)
VLLM_METAL_USE_PAGED_ATTENTION=1
# MLX 内存限制 (基于物理内存自动计算, 128GB -> ~108GB)
# MLX_MAX_MEM_GB=$(( TOTAL_MEM_GB > 0 ? TOTAL_MEM_GB * 85 / 100 : 8 ))"
  else
    engine_config="
# vLLM 标准版配置
VLLM_ENGINE=vllm
VLLM_SERVE_CMD='${engine_serve_cmd}'"
  fi

  cat > "${CONFIG_FILE}" <<EOF
# ${ENGINE} 配置文件
# 修改此文件后重启服务生效

# 模型路径或 HuggingFace 模型名
VLLM_MODEL="${DEFAULT_MODEL}"

# API 配置
VLLM_HOST=0.0.0.0
VLLM_PORT=${DEFAULT_PORT}
VLLM_SERVED_MODEL_NAME="${DEFAULT_SERVED_MODEL_NAME}"
VLLM_ENABLE_AUTO_TOOL_CHOICE=true
VLLM_TOOL_CALL_PARSER="${DEFAULT_TOOL_CALL_PARSER}"
VLLM_DISABLE_THINKING=${DEFAULT_DISABLE_THINKING}
# 自动生成的 no-think chat template 路径；留空则使用模型默认 chat template
VLLM_CHAT_TEMPLATE="${INSTALL_DIR}/chat_template_no_think.jinja"

# 性能配置
VLLM_GPU_MEMORY_UTILIZATION=${DEFAULT_GPU_MEMORY_UTILIZATION}
VLLM_MAX_MODEL_LEN=${DEFAULT_MAX_MODEL_LEN}
VLLM_TENSOR_PARALLEL_SIZE=1  # 多 GPU 时修改
VLLM_ENABLE_PREFIX_CACHING=${DEFAULT_ENABLE_PREFIX_CACHING}

# 其他配置
VLLM_MAX_NUM_SEQS=${DEFAULT_MAX_NUM_SEQS}
VLLM_MAX_NUM_BATCHED_TOKENS=${DEFAULT_MAX_NUM_BATCHED_TOKENS}
${spec_config_line}
${engine_config}

# HuggingFace Token (可选)
# HF_TOKEN=your_token_here

# 日志
VLLM_LOG_LEVEL=info
EOF
  
  success "配置已生成: ${CONFIG_FILE}"
}

generate_no_think_chat_template() {
  local runtime_model="$DEFAULT_MODEL"
  local template_file="${INSTALL_DIR}/chat_template_no_think.jinja"

  mkdir -p "${INSTALL_DIR}"
  python3 - "$runtime_model" "$template_file" <<'PY' 2>/dev/null || true
import json
import pathlib
import sys

model_ref = pathlib.Path(sys.argv[1]).expanduser()
out_file = pathlib.Path(sys.argv[2]).expanduser()
tokenizer_config = model_ref / "tokenizer_config.json"
if not tokenizer_config.is_file():
    sys.exit(0)

data = json.loads(tokenizer_config.read_text(encoding="utf-8"))
template = data.get("chat_template")
if not isinstance(template, str) or not template:
    sys.exit(0)

old = """{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\\n' }}
    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\\n\\n</think>\\n\\n' }}
    {%- else %}
        {{- '<think>\\n' }}
    {%- endif %}
{%- endif %}"""
new = """{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\\n<think>\\n\\n</think>\\n\\n' }}
{%- endif %}"""
if old in template:
    template = template.replace(old, new)
else:
    sys.exit(0)


old_system_check = """{%- if message.role == "system" %}
        {%- if not loop.first %}
            {{- raise_exception('System message must be at the beginning.') }}
        {%- endif %}"""
new_system_check = """{%- if message.role == "system" %}
        {%- if not loop.first %}
            {{- '<|im_start|>system\\n' + content + '<|im_end|>\\n' }}
        {%- endif %}"""
template = template.replace(old_system_check, new_system_check)

out_file.write_text(template, encoding="utf-8")

PY

  if [[ -f "$template_file" ]]; then
    success "已生成 no-think chat template: $template_file"
  else
    warn "未生成 no-think chat template；模型可能不是本地目录或模板格式不匹配。"
  fi
}

# --------------------------- 服务管理 ----------------------------------------
generate_systemd_service() {
  local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

  cat > /tmp/${SERVICE_NAME}.service <<EOF
[Unit]
Description=${ENGINE} Inference Service
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${INSTALL_DIR}/start.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  
  sudo mv /tmp/${SERVICE_NAME}.service ${service_file}
  sudo systemctl daemon-reload
  sudo systemctl enable ${SERVICE_NAME}
  
  success "systemd 服务已创建: ${SERVICE_NAME}"
  return 0
}

generate_macos_service() {
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_file="${plist_dir}/${SERVICE_NAME}.plist"
  
  mkdir -p "${plist_dir}"
  
  cat > "${plist_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SERVICE_NAME}</string>
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${INSTALL_DIR}/start.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>SoftResourceLimits</key>
  <dict>
    <key>NumberOfFiles</key>
    <integer>${DEFAULT_MAX_FILES_SOFT}</integer>
  </dict>
  <key>HardResourceLimits</key>
  <dict>
    <key>NumberOfFiles</key>
    <integer>${DEFAULT_MAX_FILES_SOFT}</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${INSTALL_DIR}/vllm.log</string>
  <key>StandardErrorPath</key>
  <string>${INSTALL_DIR}/vllm_error.log</string>
</dict>
</plist>
EOF

  if ! plutil -lint "${plist_file}" >/dev/null 2>&1; then
    error "LaunchAgent plist 校验失败: ${plist_file}"
    return 1
  fi

  local domain="gui/$(id -u)"
  local service_target="${domain}/${SERVICE_NAME}"

  launchctl bootout "$domain" "${plist_file}" 2>/dev/null || launchctl unload "${plist_file}" 2>/dev/null || true

  # 关键: 若服务此前被 disable (launchctl print-disabled 显示 "vllm" => disabled)，
  # 直接 bootstrap 会返回 "5: Input/output error"。必须先 enable 解除禁用状态。
  launchctl enable "$service_target" 2>/dev/null || true

  local bootstrap_err="" bootstrap_rc=0
  bootstrap_err=$(launchctl bootstrap "$domain" "${plist_file}" 2>&1) || bootstrap_rc=$?
  if [[ "$bootstrap_rc" -ne 0 ]]; then
    # 兜底: 再 enable 后重试一次
    launchctl enable "$service_target" 2>/dev/null || true
    bootstrap_rc=0
    bootstrap_err=$(launchctl bootstrap "$domain" "${plist_file}" 2>&1) || bootstrap_rc=$?
    if [[ "$bootstrap_rc" -ne 0 ]]; then
      error "macOS LaunchAgent 启动失败，无法注册服务: ${plist_file}"
      [[ -n "$bootstrap_err" ]] && error "launchctl: ${bootstrap_err}"
      error "可手动排查: launchctl print-disabled ${domain} | grep ${SERVICE_NAME}"
      return 1
    fi
  fi
  if ! launchctl kickstart -k "$service_target" 2>/dev/null; then
    warn "launchctl kickstart 返回失败，服务可能尚未完全就绪。"
  fi

  if ! launchctl print "$service_target" >/dev/null 2>&1; then
    error "LaunchAgent 注册后未能在 launchctl 中确认: ${SERVICE_NAME}"
    return 1
  fi
  
  success "macOS LaunchAgent 已创建: ${SERVICE_NAME}"
  return 0
}

optimize_macos_system_limits() {
  [[ "$OS" == "macos" ]] || return 0
  command -v launchctl >/dev/null 2>&1 || return 0

  local current_soft current_hard daemon_plist tmp_plist
  current_soft=$(launchctl limit maxfiles 2>/dev/null | awk '/maxfiles/ {print $2; exit}' || true)
  current_hard=$(launchctl limit maxfiles 2>/dev/null | awk '/maxfiles/ {print $3; exit}' || true)

  if [[ "${current_soft:-0}" =~ ^[0-9]+$ ]] && (( current_soft >= DEFAULT_MAX_FILES_SOFT )); then
    info "macOS maxfiles 已满足: soft=${current_soft}, hard=${current_hard:-unknown}"
    return 0
  fi

  warn "macOS 当前 maxfiles 偏低: soft=${current_soft:-unknown}, hard=${current_hard:-unknown}；vLLM 多并发建议提升到 ${DEFAULT_MAX_FILES_SOFT}/${DEFAULT_MAX_FILES_HARD}。"

  if [[ ! -t 0 ]]; then
    warn "当前不是交互终端，跳过 sudo 优化。请手动执行:"
    echo "  sudo launchctl limit maxfiles ${DEFAULT_MAX_FILES_SOFT} ${DEFAULT_MAX_FILES_HARD}"
    echo "  sudo cp /tmp/com.aihub.limit.maxfiles.plist /Library/LaunchDaemons/com.aihub.limit.maxfiles.plist"
    return 0
  fi

  daemon_plist="/Library/LaunchDaemons/com.aihub.limit.maxfiles.plist"
  tmp_plist="/tmp/com.aihub.limit.maxfiles.plist"
  cat > "$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.aihub.limit.maxfiles</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/launchctl</string>
    <string>limit</string>
    <string>maxfiles</string>
    <string>${DEFAULT_MAX_FILES_SOFT}</string>
    <string>${DEFAULT_MAX_FILES_HARD}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

  if ! plutil -lint "$tmp_plist" >/dev/null 2>&1; then
    warn "系统 maxfiles LaunchDaemon plist 校验失败，跳过系统级持久化。"
    return 0
  fi

  info "正在通过 sudo 优化 macOS maxfiles；如提示密码，请输入当前用户密码。"
  sudo launchctl limit maxfiles "${DEFAULT_MAX_FILES_SOFT}" "${DEFAULT_MAX_FILES_HARD}" || {
    warn "sudo launchctl limit maxfiles 失败，继续使用用户级 LaunchAgent 限制。"
    return 0
  }
  sudo cp "$tmp_plist" "$daemon_plist"
  sudo chown root:wheel "$daemon_plist"
  sudo chmod 644 "$daemon_plist"
  sudo launchctl bootstrap system "$daemon_plist" 2>/dev/null || sudo launchctl load -w "$daemon_plist" 2>/dev/null || true
  success "macOS maxfiles 已优化并持久化: ${DEFAULT_MAX_FILES_SOFT}/${DEFAULT_MAX_FILES_HARD}"
}

# --------------------------- 端口冲突检测 ----------------------------
# vLLM 服务进程匹配模式 (覆盖 vllm/vllm-mlx/vllm-metal 各种启动形态)，
# 供 wait_for_service_startup / print_service_logs_hint 等统一使用，避免遗漏导致误报。
vllm_proc_pattern() {
  printf '%s' "${VENV_DIR}/bin/vllm-mlx|vllm-mlx serve|vllm.entrypoints.openai.api_server|${VENV_DIR}/bin/vllm serve|/vllm serve|VLLM::EngineCore|vllm serve "
}

get_port_pid() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | head -1
  fi
}

get_pid_cmd() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  ps -p "$pid" -o command= 2>/dev/null | head -1
}

get_lan_ip() {
  local ip=""
  if [[ "$OS" == "macos" ]]; then
    ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  fi
  [[ -z "$ip" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  printf '%s\n' "$ip"
}

api_models_available() {
  local base_url="$1"
  curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 "${base_url}/models" >/dev/null 2>&1
}

wait_for_api() {
  local base_url="$1"
  local timeout="${2:-${VLLM_API_WAIT_SECONDS:-20}}"
  local elapsed=0

  while (( elapsed < timeout )); do
    if api_models_available "$base_url"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  return 1
}

clear_service_logs() {
  mkdir -p "${INSTALL_DIR}"
  : > "${INSTALL_DIR}/vllm.log"
  : > "${INSTALL_DIR}/vllm_error.log"
  info "已清理本次启动日志: ${INSTALL_DIR}/vllm.log, ${INSTALL_DIR}/vllm_error.log"
}

start_log_follow() {
  if [[ "${VLLM_SHOW_STARTUP_LOGS:-1}" == "0" ]]; then
    return 0
  fi

  (
    tail -n 0 -F "${INSTALL_DIR}/vllm.log" "${INSTALL_DIR}/vllm_error.log" 2>/dev/null &
    echo $! > "${INSTALL_DIR}/.vllm_tail.pid"
    wait 2>/dev/null || true
  ) &
  echo $! > "${INSTALL_DIR}/.vllm_tail_wrapper.pid"
}

stop_log_follow() {
  local pid
  if [[ -f "${INSTALL_DIR}/.vllm_tail.pid" ]]; then
    pid=$(cat "${INSTALL_DIR}/.vllm_tail.pid" 2>/dev/null || true)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "${INSTALL_DIR}/.vllm_tail.pid"
  fi
  if [[ -f "${INSTALL_DIR}/.vllm_tail_wrapper.pid" ]]; then
    pid=$(cat "${INSTALL_DIR}/.vllm_tail_wrapper.pid" 2>/dev/null || true)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "${INSTALL_DIR}/.vllm_tail_wrapper.pid"
  fi
}

detect_startup_error() {
  local error_log="${INSTALL_DIR}/vllm_error.log"
  local non_info
  [[ -f "$error_log" ]] || return 1

  non_info=$(grep -Ev "^[[:space:]]*INFO:|^INFO:vllm_mlx|^INFO:vllm|^INFO:uvicorn" "$error_log" 2>/dev/null || true)
  if printf '%s\n' "$non_info" | grep -Eiq \
    "Traceback|Exception|Error:|error:|unrecognized arguments|Address already in use|No such file|ModuleNotFoundError|ImportError|out of memory|insufficient memory|metal::|MTLCreateSystemDefaultDevice|EngineCore.*failed|Engine core initialization failed|Failed core proc|std::bad_alloc|Abort trap|killed|SIGABRT"; then
    return 0
  fi

  return 1
}

wait_for_service_startup() {
  local base_url="$1"
  local timeout="${2:-$(api_wait_seconds)}"
  local elapsed=0
  local pid=""
  local missing_streak=0
  # vllm-metal 进程形态多样: vllm serve / VLLM::EngineCore / api_server，需全部覆盖，
  # 否则会把正在加载的进程误判为"已退出"。
  local proc_pat
  proc_pat="$(vllm_proc_pattern)"

  info "等待 API 就绪: ${base_url} (最多 ${timeout}s)"

  while (( elapsed < timeout )); do
    if api_models_available "$base_url"; then
      success "vLLM API 已就绪: ${base_url}"
      return 0
    fi

    pid=$(pgrep -f "$proc_pat" 2>/dev/null | head -1 || true)
    if [[ -z "$pid" ]]; then
      # KeepAlive 重启或进程切换瞬间可能短暂匹配不到，连续 3 次(~6s)无进程才判定退出，
      # 避免误报。
      missing_streak=$((missing_streak + 1))
      if (( missing_streak >= 3 )); then
        if detect_startup_error; then
          error "vLLM 启动失败，错误日志已输出。"
        else
          error "vLLM 进程已退出，端口未监听 (连续 ${missing_streak} 次未发现进程)。"
        fi
        return 1
      fi
    else
      missing_streak=0
    fi

    if detect_startup_error; then
      error "检测到 vLLM 错误日志，启动失败。"
      return 1
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  warn "vLLM 仍在启动中或卡在模型加载阶段，端口 ${DEFAULT_PORT} 尚未监听。"
  return 2
}

service_running_hint() {
  if [[ "$OS" == "macos" ]] && command -v launchctl >/dev/null 2>&1; then
    if launchctl print "gui/$(id -u)/${SERVICE_NAME}" >/dev/null 2>&1; then
      get_port_pid "$DEFAULT_PORT" >/dev/null 2>&1 || pgrep -f "vllm|vllm-mlx" >/dev/null 2>&1
    else
      return 1
    fi
  elif [[ "$OS" == "linux" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null
  else
    pgrep -f "vllm|vllm-mlx" >/dev/null 2>&1
  fi
}

print_service_logs_hint() {
  local pid cmd port_pid
  if [[ "$OS" == "macos" ]]; then
    info "查看日志: tail -f ${INSTALL_DIR}/vllm.log ${INSTALL_DIR}/vllm_error.log"
    info "查看服务: launchctl print gui/$(id -u)/${SERVICE_NAME}"
  elif [[ "$OS" == "linux" ]] && command -v systemctl >/dev/null 2>&1; then
    info "查看日志: journalctl -u ${SERVICE_NAME} -f"
  else
    info "查看日志: tail -f ${INSTALL_DIR}/vllm*.log"
  fi

  pid=$(pgrep -f "$(vllm_proc_pattern)" 2>/dev/null | head -1 || true)
  if [[ -n "$pid" ]]; then
    cmd=$(get_pid_cmd "$pid" || true)
    info "vLLM 进程: PID ${pid} ${cmd}"
  else
    warn "未发现 vLLM 进程，服务可能已经退出。"
  fi

  port_pid=$(get_port_pid "$DEFAULT_PORT" || true)
  if [[ -n "$port_pid" ]]; then
    info "端口 ${DEFAULT_PORT}: 已监听 (PID ${port_pid})"
  else
    warn "端口 ${DEFAULT_PORT}: 未监听"
  fi
}

cleanup_stale_vllm_processes() {
  # 启动新服务前清理残留的 vllm 进程，防止多套实例叠加把统一内存吃满导致 OOM(SIGABRT)。
  # 仅清理本 venv 下或 vllm-metal 引擎的进程，不误伤 ds4/ollama 等其它 AI 服务。
  local patterns=(
    "${VENV_DIR}/bin/vllm serve"
    "${VENV_DIR}/bin/vllm-mlx"
    "vllm.entrypoints.openai.api_server"
    "${INSTALL_DIR}/start.sh"
  )
  local found=false pat pids
  for pat in "${patterns[@]}"; do
    pids=$(pgrep -f "$pat" 2>/dev/null | grep -v "^$$\$" || true)
    if [[ -n "$pids" ]]; then
      found=true
      break
    fi
  done
  # VLLM::EngineCore 进程名不含 venv 路径，单独匹配 (仅 vllm-metal/标准 vllm 会产生)
  if [[ "$found" != "true" ]] && pgrep -f "VLLM::EngineCore" >/dev/null 2>&1; then
    found=true
  fi
  [[ "$found" == "true" ]] || return 0

  info "检测到残留的 vLLM 进程，先清理以释放内存，避免多实例叠加 OOM..."
  for pat in "${patterns[@]}" "VLLM::EngineCore"; do
    pkill -TERM -f "$pat" 2>/dev/null || true
  done
  sleep 3
  # 仍存活的强制结束
  for pat in "${patterns[@]}" "VLLM::EngineCore"; do
    pkill -KILL -f "$pat" 2>/dev/null || true
  done
  sleep 1
  local mem_now
  mem_now=$(get_available_mem_gb 2>/dev/null || echo "?")
  info "残留进程已清理，当前可用内存约 ${mem_now}GB。"
}

observe_service_startup() {
  local wait_seconds rc=0
  cleanup_stale_vllm_processes
  clear_service_logs
  start_log_follow
  setup_service || {
    rc=$?
    stop_log_follow
    print_service_logs_hint
    return "$rc"
  }
  wait_seconds=$(api_wait_seconds)
  wait_for_service_startup "http://localhost:${DEFAULT_PORT}/v1" "$wait_seconds" || rc=$?
  stop_log_follow
  print_service_logs_hint
  return "$rc"
}

# 解决端口冲突。返回 0=可用（或已处理），返回 1=已切换端口（DEFAULT_PORT 已更新）
ensure_port_available() {
  local port="${DEFAULT_PORT}"
  local pid cmd
  pid=$(get_port_pid "$port")
  [[ -z "$pid" ]] && return 0

  cmd=$(get_pid_cmd "$pid")
  echo ""
  warn "端口 ${port} 已被占用 (PID: ${pid})"
  info "占用进程: ${cmd}"

  # 判断是不是自己的旧 vllm 实例
  local is_self=false
  if [[ "$cmd" == *"vllm"* || "$cmd" == *"${INSTALL_DIR}/venv"* ]]; then
    is_self=true
  fi

  if $is_self; then
    info "识别为旧 vLLM 实例，将自动结束以释放端口。"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      warn "SIGTERM 未生效，发送 SIGKILL..."
      kill -KILL "$pid" 2>/dev/null || true
      sleep 1
    fi
    if [[ -n "$(get_port_pid "$port")" ]]; then
      error "端口 ${port} 仍被占用，请手动处理后重试。"
      return 2
    fi
    success "端口 ${port} 已释放。"
    return 0
  fi

  # 非自身进程：交互让用户选择
  if [[ ! -t 0 ]]; then
    warn "非交互模式：端口冲突且非 vLLM 自身进程，跳过自启动配置。"
    return 2
  fi

  echo ""
  info "请选择处理方式:"
  echo "  1) 结束占用进程 PID ${pid} (kill -TERM)"
  echo "  2) 改用其他端口 (将更新 vllm_config.env)"
  echo "  3) 取消，稍后手动处理"
  local choice
  read -rp "选择 [1/2/3，默认 2]: " choice
  choice="${choice:-2}"

  case "$choice" in
    1)
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        warn "进程未在 2 秒内退出，发送 SIGKILL..."
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
      fi
      if [[ -n "$(get_port_pid "$port")" ]]; then
        error "端口仍被占用，请手动处理。"
        return 2
      fi
      success "已结束 PID ${pid}，端口 ${port} 释放。"
      return 0
      ;;
    2)
      local new_port
      while :; do
        read -rp "新端口 (1024-65535): " new_port
        [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1024 && new_port <= 65535 )) || {
          warn "端口非法，请重输。"; continue
        }
        if [[ -n "$(get_port_pid "$new_port")" ]]; then
          warn "端口 ${new_port} 也被占用，请换一个。"; continue
        fi
        break
      done
      DEFAULT_PORT="$new_port"
      # 更新配置文件
      if [[ -f "$CONFIG_FILE" ]]; then
        sed -i.bak -E "s/^VLLM_PORT=.*/VLLM_PORT=${new_port}/" "$CONFIG_FILE" && rm -f "${CONFIG_FILE}.bak"
        info "已更新 ${CONFIG_FILE}: VLLM_PORT=${new_port}"
      fi
      success "已切换到端口 ${new_port}。"
      return 1
      ;;
    *)
      info "已取消，自启动服务未配置。"
      return 2
      ;;
  esac
}

setup_service() {
  info "配置自动启动服务..."

  # 启动前先解决端口冲突
  local port_rc=0
  ensure_port_available || port_rc=$?
  if [[ "$port_rc" == "2" ]]; then
    return 1
  fi
  if [[ "$port_rc" == "1" ]]; then
    generate_scripts
  fi

  if [[ "$OS" == "linux" ]] && command -v systemctl &>/dev/null; then
    generate_systemd_service
  elif [[ "$OS" == "macos" ]]; then
    optimize_macos_system_limits
    generate_macos_service
  else
    warn "不支持自动创建服务，请手动启动"
    info "手动启动命令:"
    info "  source ${VENV_DIR}/bin/activate"
    if [[ "$ENGINE" == "vllm-mlx" ]]; then
      info "  $(engine_serve_command) ${DEFAULT_MODEL} --host 0.0.0.0 --port ${DEFAULT_PORT}"
    else
      info "  $(engine_serve_command) --model ${DEFAULT_MODEL} --host 0.0.0.0 --port ${DEFAULT_PORT}"
    fi
  fi
}

# --------------------------- 启动/停止脚本 -----------------------------------
generate_scripts() {
  # start.sh - 通用启动脚本 (读取引擎类型)
  local engine_serve_cmd
  engine_serve_cmd=$(engine_serve_command)

  # 基于物理内存计算 MLX 最大可用显存 (留 15% 给系统)
  local mlx_max_mem=$(( TOTAL_MEM_GB > 0 ? TOTAL_MEM_GB * 85 / 100 : 8 ))

  cat > "${INSTALL_DIR}/start.sh" <<SCRIPT
#!/usr/bin/env bash
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "\${SCRIPT_DIR}/vllm_config.env"
source "\${SCRIPT_DIR}/venv/bin/activate"

# 抬高文件描述符上限: 默认软限制仅 256，vLLM 高并发会撞 "Too many open files"。
# 取 (硬限制, 65536) 的较小值，避免设置失败。
_fd_hard="\$(ulimit -Hn 2>/dev/null || echo 65536)"
[[ "\$_fd_hard" == "unlimited" ]] && _fd_hard=65536
if [[ "\${_fd_hard}" =~ ^[0-9]+\$ ]] && (( _fd_hard > 65536 )); then _fd_hard=65536; fi
ulimit -n "\${_fd_hard}" 2>/dev/null || ulimit -n 8192 2>/dev/null || true

echo "启动 ${ENGINE} 服务..."
echo "引擎: \${VLLM_ENGINE:-${ENGINE}}"
echo "模型: \${VLLM_MODEL}"
if [[ -n "\${VLLM_SERVED_MODEL_NAME:-}" ]]; then
  echo "对外模型名: \${VLLM_SERVED_MODEL_NAME}"
fi
echo "地址: http://\${VLLM_HOST}:\${VLLM_PORT}"
echo "文件描述符上限(ulimit -n): \$(ulimit -n)"
if [[ "\${VLLM_ENABLE_SPECULATIVE:-false}" == "true" ]] && [[ -n "\${VLLM_SPECULATIVE_CONFIG:-}" ]]; then
  echo "投机解码: 已启用 (\${VLLM_SPECULATIVE_CONFIG})"
fi
echo "按 Ctrl+C 停止服务"
echo ""

# 构建启动参数
ENGINE_TYPE="\${VLLM_ENGINE:-${ENGINE}}"
ARGS=()
if [[ "\${ENGINE_TYPE}" == "vllm-mlx" ]]; then
  ARGS+=(
    "\${VLLM_MODEL}"
    --host "\${VLLM_HOST}"
    --port "\${VLLM_PORT}"
  )
  # 针对 Apple Silicon 的加速和内存锁定变量 (128GB RAM 推荐配置)
  export MLX_GPU_DEBUG=0
  export MLX_MAX_MEM_GB="\${MLX_MAX_MEM_GB:-${mlx_max_mem}}"

  [[ "\${VLLM_MLX_CONTINUOUS_BATCHING:-false}" == "true" ]] && ARGS+=(--continuous-batching)
  [[ -n "\${VLLM_MLX_SSD_CACHE_DIR:-}" ]] && ARGS+=(--ssd-cache-dir "\${VLLM_MLX_SSD_CACHE_DIR}")
  [[ -n "\${VLLM_MLX_MOE_TOP_K:-}" ]] && ARGS+=(--moe-top-k "\${VLLM_MLX_MOE_TOP_K}")
  [[ "\${VLLM_MLX_METRICS:-false}" == "true" ]] && ARGS+=(--metrics)
  [[ -n "\${VLLM_MLX_REASONING_PARSER:-}" ]] && ARGS+=(--reasoning-parser "\${VLLM_MLX_REASONING_PARSER}")
elif [[ "\${ENGINE_TYPE}" == "vllm-metal" ]]; then
  # vllm-metal: Apple Silicon Metal+MLX 后端
  # 使用简洁参数, 不需要 --gpu-memory-utilization / --tensor-parallel-size
  ARGS+=(
    "\${VLLM_MODEL}"
    --host "\${VLLM_HOST}"
    --port "\${VLLM_PORT}"
  )
  # Metal 后端环境变量
  export VLLM_METAL_USE_PAGED_ATTENTION="\${VLLM_METAL_USE_PAGED_ATTENTION:-1}"
  export MLX_GPU_DEBUG=0
  export MLX_MAX_MEM_GB="\${MLX_MAX_MEM_GB:-${mlx_max_mem}}"
  # vllm-metal 可选参数
  [[ -n "\${VLLM_MAX_MODEL_LEN:-}" ]] && ARGS+=(--generation-config vllm --max-model-len "\${VLLM_MAX_MODEL_LEN}")
  [[ -n "\${VLLM_MAX_NUM_SEQS:-}" ]] && ARGS+=(--max-num-seqs "\${VLLM_MAX_NUM_SEQS}")
else
  # vllm: 标准 GPU 后端 (CUDA)
  ARGS+=(
    --model "\${VLLM_MODEL}"
    --host "\${VLLM_HOST}"
    --port "\${VLLM_PORT}"
    --download-dir "\${SCRIPT_DIR}/models"
    --gpu-memory-utilization "\${VLLM_GPU_MEMORY_UTILIZATION}"
    --generation-config vllm --max-model-len "\${VLLM_MAX_MODEL_LEN}"
    --tensor-parallel-size "\${VLLM_TENSOR_PARALLEL_SIZE}"
    --max-num-seqs "\${VLLM_MAX_NUM_SEQS}"
    --max-num-batched-tokens "\${VLLM_MAX_NUM_BATCHED_TOKENS}"
  )
fi

if [[ "\${VLLM_ENABLE_SPECULATIVE:-false}" == "true" ]] && [[ -n "\${VLLM_SPECULATIVE_CONFIG:-}" ]]; then
  ARGS+=(--speculative-config "\${VLLM_SPECULATIVE_CONFIG}")
fi
if [[ "\${VLLM_ENABLE_PREFIX_CACHING:-false}" == "true" ]]; then
  ARGS+=(--enable-prefix-caching)
fi
if [[ "\${VLLM_ENABLE_AUTO_TOOL_CHOICE:-false}" == "true" ]]; then
  ARGS+=(--enable-auto-tool-choice)
  if [[ -n "\${VLLM_TOOL_CALL_PARSER:-}" ]]; then
    ARGS+=(--tool-call-parser "\${VLLM_TOOL_CALL_PARSER}")
  fi
fi
if [[ "\${VLLM_DISABLE_THINKING:-false}" == "true" && -n "\${VLLM_CHAT_TEMPLATE:-}" && -f "\${VLLM_CHAT_TEMPLATE}" ]]; then
  ARGS+=(--chat-template "\${VLLM_CHAT_TEMPLATE}")
fi
if [[ -n "\${VLLM_SERVED_MODEL_NAME:-}" ]]; then
  ARGS+=(--served-model-name "\${VLLM_SERVED_MODEL_NAME}")
fi
ARGS+=("\$@")

# 使用引擎对应的启动命令
\${VLLM_SERVE_CMD:-${engine_serve_cmd}} "\${ARGS[@]}"
SCRIPT
  chmod +x "${INSTALL_DIR}/start.sh"

  # models.catalog.tsv
  cp "${SHARED_MODEL_CATALOG_FILE}" "${INSTALL_DIR}/models.catalog.tsv"

  # start_model.sh - start one model by alias/name on a custom port
  cat > "${INSTALL_DIR}/start_model.sh" <<SCRIPT
#!/usr/bin/env bash
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "\${SCRIPT_DIR}/vllm_config.env"
source "\${SCRIPT_DIR}/venv/bin/activate"

MODEL_OR_ALIAS="\${1:-}"
PORT="\${2:-8000}"
MAX_LEN="\${3:-32768}"
GPU_UTIL="\${4:-0.85}"
shift \$(( \$# >= 1 ? 1 : 0 )) || true
shift \$(( \$# >= 1 ? 1 : 0 )) || true
shift \$(( \$# >= 1 ? 1 : 0 )) || true
shift \$(( \$# >= 1 ? 1 : 0 )) || true

if [[ -z "\$MODEL_OR_ALIAS" ]]; then
  echo "用法: \$0 <模型别名或HF模型名> [端口] [上下文长度] [gpu_util] [额外参数...]"
  echo "引擎: \${VLLM_ENGINE:-${ENGINE}}"
  echo "模型目录: \${SCRIPT_DIR}/models.catalog.tsv"
  exit 1
fi

MODEL="\$MODEL_OR_ALIAS"
SERVED_MODEL_NAME="\$MODEL_OR_ALIAS"
SPEC_CONFIG=""
if [[ -f "\${SCRIPT_DIR}/models.catalog.tsv" ]]; then
  row=\$(awk -F'\\t' -v key="\$MODEL_OR_ALIAS" 'NR > 1 && (\$1 == key || \$2 == key) {print; exit}' "\${SCRIPT_DIR}/models.catalog.tsv")
  if [[ -n "\$row" ]]; then
    MODEL=\$(echo "\$row" | awk -F'\\t' '{print \$2}')
    SERVED_MODEL_NAME=\$(echo "\$row" | awk -F'\\t' '{print \$1}')
    [[ "\$MAX_LEN" == "auto" ]] && MAX_LEN=\$(echo "\$row" | awk -F'\\t' '{print \$3}')
    SPEC_CONFIG=\$(echo "\$row" | awk -F'\\t' '{print \$7}')
  fi
fi

ENGINE_TYPE="\${VLLM_ENGINE:-${ENGINE}}"
echo "启动 \${ENGINE_TYPE} 单模型服务"
echo "引擎: \${ENGINE_TYPE}"
echo "模型: \${MODEL}"
echo "对外模型名: \${SERVED_MODEL_NAME}"
echo "端口: \${PORT}"
echo "上下文: \${MAX_LEN}"
echo "地址: http://localhost:\${PORT}/v1"

# 构建引擎特定参数
ENGINE_ARGS=()
if [[ "\${ENGINE_TYPE}" == "vllm-mlx" ]]; then
  export MLX_GPU_DEBUG=0
  export MLX_MAX_MEM_GB="\${MLX_MAX_MEM_GB:-${mlx_max_mem}}"
  [[ "\${VLLM_MLX_CONTINUOUS_BATCHING:-false}" == "true" ]] && ENGINE_ARGS+=(--continuous-batching)
else
  ENGINE_ARGS+=(
    --gpu-memory-utilization "\${GPU_UTIL}"
    --max-model-len "\${MAX_LEN}"
  )
fi

SPEC_ARGS=()
if [[ -n "\$SPEC_CONFIG" ]]; then
  SPEC_ARGS=(--speculative-config "\$SPEC_CONFIG")
fi
PREFIX_ARGS=()
if [[ "\${VLLM_ENABLE_PREFIX_CACHING:-false}" == "true" ]]; then
  PREFIX_ARGS=(--enable-prefix-caching)
fi
TOOL_ARGS=()
if [[ "\${VLLM_ENABLE_AUTO_TOOL_CHOICE:-false}" == "true" ]]; then
  TOOL_ARGS+=(--enable-auto-tool-choice)
  if [[ -n "\${VLLM_TOOL_CALL_PARSER:-}" ]]; then
    TOOL_ARGS+=(--tool-call-parser "\${VLLM_TOOL_CALL_PARSER}")
  fi
fi
SERVED_MODEL_ARGS=(--served-model-name "\$SERVED_MODEL_NAME")

if [[ "\${ENGINE_TYPE}" == "vllm-mlx" ]]; then
  \${VLLM_SERVE_CMD:-${engine_serve_cmd}} \\
    "\${MODEL}" \\
    --host 0.0.0.0 \\
    --port "\${PORT}" \\
    "\${ENGINE_ARGS[@]}" \\
    "\${SPEC_ARGS[@]}" \\
    "\${PREFIX_ARGS[@]}" \\
    "\${TOOL_ARGS[@]}" \\
    "\${SERVED_MODEL_ARGS[@]}" \\
    "\$@"
else
  \${VLLM_SERVE_CMD:-${engine_serve_cmd}} \\
    --model "\${MODEL}" \\
    --host 0.0.0.0 \\
    --port "\${PORT}" \\
    --download-dir "\${SCRIPT_DIR}/models" \\
    "\${ENGINE_ARGS[@]}" \\
    "\${SPEC_ARGS[@]}" \\
    "\${PREFIX_ARGS[@]}" \\
    "\${TOOL_ARGS[@]}" \\
    "\${SERVED_MODEL_ARGS[@]}" \\
    "\$@"
fi
SCRIPT
  chmod +x "${INSTALL_DIR}/start_model.sh"

  # start_multi.sh - start several vLLM instances on different ports
  cat > "${INSTALL_DIR}/start_multi.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-${SCRIPT_DIR}/models.multi.example}"

if [[ ! -f "$CONFIG" ]]; then
  echo "未找到多模型配置: $CONFIG"
  echo "格式: 模型别名或HF模型名 端口 上下文长度 gpu_util 额外参数"
  exit 1
fi

if [[ "$(uname)" == "Darwin" ]]; then
  SYS_MEM_GB=$(($(sysctl -n hw.memsize 2>/dev/null || echo "0") / 1073741824))
else
  SYS_MEM_GB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1048576)}' || echo "0")
fi

# 计算预估内存总和
TOTAL_ESTIMATED=0
while read -r model port max_len gpu_util extra_args; do
  [[ -z "${model:-}" || "$model" == \#* ]] && continue
  if [[ -f "${SCRIPT_DIR}/models.catalog.tsv" ]]; then
    mem=$(awk -F'\t' -v key="$model" 'NR > 1 && ($1 == key || $2 == key) {print $4; exit}' "${SCRIPT_DIR}/models.catalog.tsv")
    [[ -n "$mem" && "$mem" =~ ^[0-9]+$ ]] && TOTAL_ESTIMATED=$((TOTAL_ESTIMATED + mem))
  fi
done < "$CONFIG"

if [[ "$SYS_MEM_GB" -gt 0 && "$TOTAL_ESTIMATED" -gt $((SYS_MEM_GB * 90 / 100)) ]]; then
  echo -e "\033[0;31m[警告] 多模型预估内存总和 (~${TOTAL_ESTIMATED}GB) 超过系统总内存的 90% (${SYS_MEM_GB}GB)！\033[0m"
  echo "这极易导致系统触发 Swap，甚至引发内核 OOM 崩溃。"
  read -p "是否强制继续启动？(y/N): " force_run
  [[ ! "$force_run" =~ ^[Yy]$ ]] && exit 1
fi

mkdir -p "${SCRIPT_DIR}/logs"
while read -r model port max_len gpu_util extra_args; do
  [[ -z "${model:-}" || "$model" == \#* ]] && continue
  port="${port:-8000}"
  max_len="${max_len:-32768}"
  gpu_util="${gpu_util:-0.80}"
  log_file="${SCRIPT_DIR}/logs/${model//\//_}-${port}.log"
  echo "启动: ${model} -> :${port} (日志: ${log_file})"
  nohup "${SCRIPT_DIR}/start_model.sh" "$model" "$port" "$max_len" "$gpu_util" ${extra_args:-} > "$log_file" 2>&1 &
done < "$CONFIG"

echo "多模型服务已后台启动。查看日志: tail -f ${SCRIPT_DIR}/logs/*.log"
echo "停止方式: ${INSTALL_DIR}/stop.sh"
SCRIPT
  chmod +x "${INSTALL_DIR}/start_multi.sh"

  cat > "${INSTALL_DIR}/models.multi.example" <<EOF
# 模型别名或HF模型名                 端口   上下文   gpu_util  额外参数
qwen3.6-27b                           8000  65536   0.70
deepseek-r1-distill-qwen-14b          8001  32768   0.35
# qwen3.6-35b-a3b                     8002  32768   0.55
# qwen3-coder-30b-a3b                 8003  32768   0.55
EOF
  
  # stop.sh
  cat > "${INSTALL_DIR}/stop.sh" <<EOF
#!/usr/bin/env bash
echo "停止 ${ENGINE} 服务..."
if command -v systemctl &>/dev/null; then
  sudo systemctl stop ${SERVICE_NAME} 2>/dev/null || true
elif command -v launchctl &>/dev/null; then
  launchctl stop ${SERVICE_NAME} 2>/dev/null || true
fi
# 使用精确匹配，并发送 SIGKILL (-9) 确保完全退出，同时清理 Apple Silicon 上经常遗留的 VLLM::EngineCore
pkill -9 -f "vllm serve" 2>/dev/null || true
pkill -9 -f "vllm-mlx serve" 2>/dev/null || true
pkill -9 -f "vllm_mlx.serve" 2>/dev/null || true
pkill -9 -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
pkill -9 -f "VLLM::EngineCore" 2>/dev/null || true
echo "服务已停止"
EOF
  chmod +x "${INSTALL_DIR}/stop.sh"
  
  # test_api.sh
  cat > "${INSTALL_DIR}/test_api.sh" <<EOF
#!/usr/bin/env bash
set -e
source "${CONFIG_FILE}"

echo "测试 vLLM API..."
echo ""

# 测试模型列表
echo "=== 模型列表 ==="
curl -s http://localhost:${DEFAULT_PORT}/v1/models | python -m json.tool

echo ""
echo "=== 生成测试 ==="
curl -s http://localhost:${DEFAULT_PORT}/v1/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "'"\${VLLM_SERVED_MODEL_NAME:-\${VLLM_MODEL}}"'",
    "prompt": "你好，请简单介绍一下你自己。",
    "max_tokens": 100,
    "temperature": 0.7
  }' | python -m json.tool

echo ""
echo "=== 聊天测试 ==="
curl -s http://localhost:${DEFAULT_PORT}/v1/chat/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "'"\${VLLM_SERVED_MODEL_NAME:-\${VLLM_MODEL}}"'",
    "messages": [
      {"role": "user", "content": "你好，请用一句话介绍你自己"}
    ],
    "max_tokens": 100,
    "temperature": 0.7
  }' | python -m json.tool
EOF
  chmod +x "${INSTALL_DIR}/test_api.sh"
  
  success "管理脚本已生成: start.sh, start_model.sh, start_multi.sh, stop.sh, test_api.sh"
}

# --------------------------- 使用提示 ----------------------------------------
print_usage() {
  local lan_ip local_base lan_base service_status lan_line verify_line
  lan_ip="$(get_lan_ip)"
  local_base="http://localhost:${DEFAULT_PORT}/v1"
  lan_base=""
  [[ -n "$lan_ip" ]] && lan_base="http://${lan_ip}:${DEFAULT_PORT}/v1"

  service_status="未验证"
  verify_line="  本机:   ${local_base}  (未验证，启动后可访问)"
  if api_models_available "$local_base"; then
    service_status="运行中，API 可用"
    verify_line="  本机:   ${local_base}  (可用)"
    if [[ -n "$lan_base" ]]; then
      if api_models_available "$lan_base"; then
        lan_line="
  局域网: ${lan_base}   (可用)"
      else
        lan_line="
  局域网: ${lan_base}   (未验证，可能被防火墙拦截或服务未监听局域网)"
      fi
    fi
  elif get_port_pid "$DEFAULT_PORT" >/dev/null 2>&1; then
    service_status="服务已加载，API 尚未就绪"
    verify_line="  本机:   ${local_base}  (启动中或启动失败，暂不可用)"
    [[ -n "$lan_base" ]] && lan_line="
  局域网: ${lan_base}   (暂不可用)"
  elif service_running_hint; then
    service_status="服务配置存在，但进程未运行"
    verify_line="  本机:   ${local_base}  (未运行)"
    [[ -n "$lan_base" ]] && lan_line="
  局域网: ${lan_base}   (未运行)"
  else
    service_status="未运行"
    verify_line="  本机:   ${local_base}  (未运行)"
    [[ -n "$lan_base" ]] && lan_line="
  局域网: ${lan_base}   (未运行)"
  fi

  cat <<EOF

$(success "${ENGINE} 配置完成  (模型: ${DEFAULT_MODEL})")
  服务状态: ${service_status}
${verify_line}${lan_line}

$(info "常用命令:")
  启动: ${INSTALL_DIR}/start.sh           停止: ${INSTALL_DIR}/stop.sh
  测试: ${INSTALL_DIR}/test_api.sh        日志: tail -f ${INSTALL_DIR}/vllm*.log

$(info "快速验证:")
  curl ${local_base}/models${lan_base:+
  curl ${lan_base}/models   # 局域网}

$(info "更多用法:") VLLM_VERBOSE=1 $0  或  cat ${CONFIG_FILE}
EOF

  [[ "${VLLM_VERBOSE:-0}" == "1" ]] || return 0

  cat <<EOF

$(info "安装目录:") ${INSTALL_DIR}
$(info "虚拟环境:") ${VENV_DIR}
$(info "模型目录:") ${MODEL_DIR}
$(info "配置文件:") ${CONFIG_FILE}
$(info "引擎/GPU:") ${ENGINE} / ${GPU_TYPE}

$(info "管理命令:")
  启动服务:   ${INSTALL_DIR}/start.sh
  启动单模型: ${INSTALL_DIR}/start_model.sh qwen3.6-27b 8000 auto 0.70
  启动多模型: ${INSTALL_DIR}/start_multi.sh ${INSTALL_DIR}/models.multi.example
  停止服务:   ${INSTALL_DIR}/stop.sh
  测试 API:   ${INSTALL_DIR}/test_api.sh

$(info "服务地址:") http://localhost:${DEFAULT_PORT}  (Base URL: /v1, Docs: /docs)
EOF

  # 引擎特定提示
  if [[ "$ENGINE" == "vllm-mlx" ]]; then
    cat <<EOF

$(info "vllm-mlx 额外功能:")
  $(yellow "Gradio 聊天界面:") vllm-mlx-chat
  $(yellow "纯文本聊天界面:") vllm-mlx-text-chat
  $(yellow "基准测试:") vllm-mlx-bench
  $(yellow "Anthropic API:") http://localhost:${DEFAULT_PORT}/v1/messages
  $(yellow "MCP 工具调用:") 支持 (12 种解析器)
  $(yellow "嵌入端点:") http://localhost:${DEFAULT_PORT}/v1/embeddings
  $(yellow "Rerank 端点:") http://localhost:${DEFAULT_PORT}/v1/rerank
  $(yellow "Prometheus 指标:") http://localhost:${DEFAULT_PORT}/metrics
EOF
  elif [[ "$ENGINE" == "vllm-metal" ]]; then
    cat <<EOF

$(info "vllm-metal 环境变量:")
  $(yellow "内存分配:") VLLM_METAL_MEMORY_FRACTION=auto
  $(yellow "MLX 开关:") VLLM_METAL_USE_MLX=1
  $(yellow "设备选择:") VLLM_MLX_DEVICE=gpu
EOF
  fi

  cat <<EOF

$(info "使用 OpenAI SDK 调用示例:")
  from openai import OpenAI
  client = OpenAI(base_url="http://localhost:${DEFAULT_PORT}/v1", api_key="none")
  response = client.chat.completions.create(
      model="${DEFAULT_MODEL}",
      messages=[{"role": "user", "content": "你好"}]
  )
  print(response.choices[0].message.content)

$(warn "提示:")
  - 修改配置: 编辑 ${CONFIG_FILE} 后重启服务
  - 查看模型目录: column -t -s \$'\t' ${INSTALL_DIR}/models.catalog.tsv
  - 编码优先: qwen3.6-27b -> qwen3.6-35b-a3b -> qwen3-coder-30b-a3b
  - PRD/画图: qwen3-30b-a3b -> glm-4.6 -> gemma3-27b
  - 下载模型: huggingface-cli download <model> --local-dir ${MODEL_DIR}/<name>
  - 查看日志: tail -f ${INSTALL_DIR}/vllm*.log (macOS) 或 journalctl -u ${SERVICE_NAME} (Linux)
  - 切换引擎: 重新运行 $0 -e <vllm|vllm-mlx|vllm-metal>

EOF
}

# --------------------------- 性能测试 ----------------------------------------
measure_disk_speed() {
  local target_dir="$1"
  local test_file="${target_dir}/.speedtest_vllm_tmp"
  
  # 使用 dd 进行简单的写入测速 (256MB)
  # macOS dd 输出格式: 268435456 bytes transferred in 0.123456 secs (2174354560 bytes/sec)
  local speed_out
  speed_out=$(dd if=/dev/zero of="$test_file" bs=1M count=256 2>&1 | grep "bytes/sec" || echo "")
  
  if [[ -n "$speed_out" ]]; then
    # 提取 bytes/sec 并转换为 MB/s
    local bps
    bps=$(echo "$speed_out" | sed -E 's/.* \(([0-9]+) bytes\/sec\).*/\1/')
    echo $((bps / 1024 / 1024))
  else
    echo "0"
  fi
  rm -f "$test_file"
}

# --------------------------- 主流程 ------------------------------------------
optimize_storage() {
  if [[ "$OS" != "macos" ]]; then return 0; fi
  
  # 获取所有外部挂载盘信息
  local disks_info
  disks_info=$(df -g | awk '$9 ~ "^/Volumes/" && $9 !~ /TimeMachine|Recovery/ {print $2 "\t" $4 "\t" $9}' | sort -nr -k1,1 || true)
  
  if [[ -z "$disks_info" ]]; then
    return 0
  fi

  local best_disk_info
  best_disk_info=$(echo "$disks_info" | head -n1)
  local ext_cap ext_free ext_path
  ext_cap=$(echo "$best_disk_info" | awk -F'\t' '{print $1}')
  ext_free=$(echo "$best_disk_info" | awk -F'\t' '{print $2}')
  ext_path=$(echo "$best_disk_info" | awk -F'\t' '{print $3}')

  echo -e "\n${CYAN}正在评估存储性能...${NC}"
  local internal_speed=$(measure_disk_speed "$HOME")
  local external_speed=$(measure_disk_speed "$ext_path")

  echo -e "  - 内置 SSD 写入速度: ${YELLOW}${internal_speed} MB/s${NC}"
  echo -e "  - 外部硬盘 写入速度: ${YELLOW}${external_speed} MB/s${NC}"

  local gap_ok=false
  # 如果外部速度达到内置的 40% 以上，或者绝对速度超过 1500MB/s (雷电 3/4)，则认为差距不明显
  if [[ $internal_speed -gt 0 ]]; then
    local ratio=$((external_speed * 100 / internal_speed))
    if [[ $ratio -ge 40 || $external_speed -ge 1500 ]]; then
      gap_ok=true
    fi
  fi

  echo -e "\n${BLUE}┌──────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BLUE}│${NC}  ${BOLD}存储策略建议 (针对 Mac Studio 优化)${NC}                 ${BLUE}│${NC}"
  echo -e "${BLUE}├──────────────────────────────────────────────────────────┤${NC}"
  echo -e "  检测到外部硬盘: ${CYAN}${ext_path}${NC} (${ext_free} GB 可用 / ${ext_cap} GB 总量)"
  
  if $gap_ok; then
    echo -e "  ${GREEN}评估结果: 外部硬盘读写性能极佳 (雷电/高阶连接)${NC}"
    echo -e "  ${BOLD}推荐策略: 优先使用外部硬盘${NC}"
    echo -e "  - 将所有 AI 模型、HF 缓存迁移至外部磁盘，保护内置 SSD 空间。"
    echo -e "  - 内置 SSD 仅保留 Python 运行时环境。"
  else
    echo -e "  ${YELLOW}评估结果: 外部硬盘与内置 SSD 存在明显性能代差${NC}"
    echo -e "  ${BOLD}推荐策略: 混合分级存储${NC}"
    echo -e "  1. ${BOLD}核心高频模型${NC} -> ${YELLOW}保留在内置高速 SSD${NC}"
    echo -e "  2. ${BOLD}低频大模型 & HF 缓存${NC} -> ${GREEN}迁移至外部盘${NC}"
  fi
  echo -e "${BLUE}└──────────────────────────────────────────────────────────┘${NC}"
  
  local prompt_msg="是否将默认下载目录整体映射到外部磁盘？"
  $gap_ok && prompt_msg="是否应用优先外部硬盘策略？"
  
  if confirm "$prompt_msg" "n"; then
    local target_base="${ext_path}/vllm_data"
    mkdir -p "${target_base}/models"
    mkdir -p "${target_base}/hf_cache"
    
    info "正在建立软链接，映射空间到 ${ext_path}..."
    
    # 确保主安装目录存在
    mkdir -p "${INSTALL_DIR}"
    
    # 1. 处理模型目录
    if [[ -L "${MODEL_DIR}" ]]; then
      rm -f "${MODEL_DIR}"
    elif [[ -d "${MODEL_DIR}" && -n "$(ls -A "${MODEL_DIR}" 2>/dev/null)" ]]; then
      warn "检测到已有模型目录非空: ${MODEL_DIR}"
      if confirm "是否迁移已有模型到外部磁盘" "y"; then
        info "正在迁移已有模型到: ${target_base}/models"
        shopt -s dotglob nullglob
        mv "${MODEL_DIR}"/* "${target_base}/models/" 2>/dev/null || true
        shopt -u dotglob nullglob
        rmdir "${MODEL_DIR}" 2>/dev/null || true
      else
        warn "保留现有模型目录，跳过模型目录软链接。"
      fi
    fi
    if [[ ! -e "${MODEL_DIR}" ]]; then
      ln -sfn "${target_base}/models" "${MODEL_DIR}"
      info "模型目录映射: ${MODEL_DIR} -> ${target_base}/models"
    fi
    
    # 2. 处理 HuggingFace 缓存
    local hf_home="${HOME}/.cache/huggingface"
    mkdir -p "$(dirname "$hf_home")"
    
    if [[ -d "${hf_home}" && ! -L "${hf_home}" ]]; then
      info "正在迁移现有缓存 (可能需要一点时间)..."
      mv "${hf_home}"/* "${target_base}/hf_cache/" 2>/dev/null || true
      rm -rf "${hf_home}"
    fi
    ln -sfn "${target_base}/hf_cache" "${hf_home}"
    info "HF 缓存映射: ${hf_home} -> ${target_base}/hf_cache"
    
    success "存储策略已激活！数据将安全地存储在外部磁盘。"
  fi
}

# --------------------------- 内存清理（按需触发） ----------------------------
# 仅在资源不富裕时触发：可用内存不足以装载目标模型，或检测到已知大户进程。
# 列出 RSS > 2GB 的 Top 10 进程，让用户多选 kill -TERM，默认全跳过。
get_available_mem_gb() {
  if [[ "$OS" == "macos" ]]; then
    local page_size free spec inactive
    page_size=$(vm_stat | awk '/page size of/ {print $8; exit}')
    [[ -z "$page_size" ]] && page_size=16384
    free=$(vm_stat | awk '/Pages free/ {gsub("\\.","",$3); print $3; exit}')
    spec=$(vm_stat | awk '/Pages speculative/ {gsub("\\.","",$3); print $3; exit}')
    inactive=$(vm_stat | awk '/Pages inactive/ {gsub("\\.","",$3); print $3; exit}')
    echo $(( ( (${free:-0} + ${spec:-0} + ${inactive:-0}) * page_size ) / 1073741824 ))
  else
    awk '/MemAvailable/ {print int($2/1048576); exit}' /proc/meminfo 2>/dev/null || echo 0
  fi
}

list_top_processes() {
  # 输出: PID|RSS_GB|COMMAND
  # 策略:
  #   - 已知 AI 推理进程 (ds4-server/ollama/vllm/llama-server/lmstudio) 无条件纳入
  #     （它们常用 mmap 加载大模型，RSS 在统一内存下可能只有几百 MB）
  #   - 其它进程要求 RSS > 500MB 才进入候选
  #   - 按 RSS 倒序最多 10 条
  local self_pid=$$ ppid=$PPID
  local ps_cmd
  if [[ "$OS" == "macos" ]]; then
    ps_cmd="ps -axo pid=,user=,rss=,command="
  else
    ps_cmd="ps -eo pid=,user=,rss=,command="
  fi

  $ps_cmd 2>/dev/null \
    | awk -v self="$self_pid" -v par="$ppid" '
        $1 == self || $1 == par { next }
        {
          rss = $3 + 0
          cmd = ""
          for (i=4; i<=NF; i++) cmd = cmd (i==4?"":" ") $i
          # 排除当前安装脚本及子进程 (含 vllm 字样但不是真正的 vllm 服务)
          if (cmd ~ /install[_-]vllm\.sh/) next
          if (cmd ~ /install[_-]ds4\.sh/) next
          # 只挑真正的 AI 服务: 命令名以 vllm/ollama/llama-server/ds4-server 开头或绝对路径精确匹配
          is_ai = (cmd ~ /(^|\/)(ds4-server|ollama|lmstudio|llama-server|llama\.cpp)/ \
                   || cmd ~ /(^|\/)vllm($| serve| -)/ \
                   || cmd ~ /vllm-mlx serve/ \
                   || cmd ~ /vllm\.entrypoints/)
          if (is_ai || rss > 524288) {
            rss_gb = rss / 1048576
            printf "%s|%.2f|%s\n", $1, rss_gb, cmd
          }
        }' \
    | sort -t'|' -k2,2 -nr | head -n 10
}

reclaim_memory_if_tight() {
  [[ "${VLLM_RECLAIM_MEMORY:-0}" == "1" ]] || return 0

  # 非交互模式直接跳过（curl | bash 场景不打扰）
  [[ -t 0 ]] || return 0

  local target_mem available_mem
  target_mem=$(model_memory_gb "$DEFAULT_MODEL")
  [[ -z "$target_mem" || "$target_mem" == "0" ]] && target_mem=16
  available_mem=$(get_available_mem_gb)

  # 触发条件:
  #   1) 目标模型预估内存 > 可用内存 * 0.8 → 才需要真正提示
  #   2) 单独检测到 AI 推理进程不算"资源紧张"，只在内存不足时一并显示
  local need_reclaim=false reason=""
  local threshold=$(( target_mem * 100 / 80 ))
  if (( available_mem < threshold )); then
    need_reclaim=true
    reason="可用内存 ${available_mem}GB 不足以装载 ${DEFAULT_MODEL} (~${target_mem}GB, 阈值 ${threshold}GB)"
  fi

  $need_reclaim || return 0

  echo ""
  warn "资源不富裕检测: ${reason}"
  info "以下是当前占用较大的进程 (AI 服务无条件列出 + 其他 RSS > 500MB):"
  echo ""

  local rows=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(list_top_processes)

  if [[ ${#rows[@]} -eq 0 ]]; then
    info "未发现可清理的大内存进程，继续安装。"
    return 0
  fi

  printf "  %-4s %-8s %-10s %s\n" "编号" "PID" "RSS(GB)" "命令"
  printf "  %-4s %-8s %-10s %s\n" "----" "--------" "----------" "----"
  local i=1
  for row in "${rows[@]}"; do
    local pid rss cmd
    pid=$(echo "$row" | awk -F'|' '{print $1}')
    rss=$(echo "$row" | awk -F'|' '{print $2}')
    cmd=$(echo "$row" | awk -F'|' '{print $3}' | cut -c1-70)
    printf "  %-4s %-8s %-10s %s\n" "$i" "$pid" "$rss" "$cmd"
    i=$((i+1))
  done
  echo ""

  local selected
  read -rp "输入要结束的编号 (空格分隔，如: 1 3 5；回车跳过): " selected
  [[ -z "${selected:-}" ]] && { info "已跳过进程清理。"; return 0; }

  local choice
  for choice in $selected; do
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "忽略无效编号: $choice"; continue; }
    local idx=$((choice - 1))
    if (( idx < 0 || idx >= ${#rows[@]} )); then
      warn "忽略越界编号: $choice"; continue
    fi
    local pid cmd
    pid=$(echo "${rows[idx]}" | awk -F'|' '{print $1}')
    cmd=$(echo "${rows[idx]}" | awk -F'|' '{print $3}' | cut -c1-50)
    info "发送 SIGTERM 到 PID ${pid} (${cmd})..."
    if kill -TERM "$pid" 2>/dev/null; then
      success "已请求终止: ${pid}"
    else
      warn "无法终止 ${pid}（可能权限不足或进程已退出）"
    fi
  done

  # 给进程一点退出时间
  sleep 2
  local new_avail
  new_avail=$(get_available_mem_gb)
  info "清理后可用内存: ${new_avail}GB"
  echo ""
}

print_runtime_tradeoffs() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  vLLM 资源取舍建议 (M4 Max 128G / AI 服务器)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  当前默认:"
  echo "    模型:        ${DEFAULT_MODEL}"
  echo "    上下文:      ${DEFAULT_MAX_MODEL_LEN} tokens"
  echo "    并发序列:    ${DEFAULT_MAX_NUM_SEQS}"
  echo "    批处理上限:  ${DEFAULT_MAX_NUM_BATCHED_TOKENS} tokens"
  echo "    Prefix缓存:  ${DEFAULT_ENABLE_PREFIX_CACHING}"
  echo ""
  echo "  关系:"
  echo "    上下文越大，单请求可读内容越多，但 KV cache 占用越高。"
  echo "    并发越大，可同时服务的人越多，但每个请求可用 KV 预算下降。"
  echo "    输出越长，用户等待越久；不影响输入上下文，但会占用总 token 预算。"
  echo ""
  echo "  推荐档位:"
  echo "    64K + seq=4   当前默认，单人优先响应和稳定性。"
  echo "    64K + seq=6   2-3 人编码/脚本审查推荐。"
  echo "    64K + seq=8   短请求多、长请求少时可尝试，注意内存压力。"
  echo "    128K + seq=3  超长文档/大代码审查专用，不建议多人默认。"
  echo "    32K + seq=8+  短问答吞吐优先，但容易遇到大文件上下文上限。"
  echo ""
  echo "  加速原则:"
  echo "    不换小模型、不降低上下文时，生成速度主要受 27B dense 模型解码速度限制。"
  echo "    Prefix caching 可复用重复系统提示/工具定义/项目上下文，不改变准确性。"
  echo "    Speculative decoding 可能加速，但需单独验证兼容性；默认不强开。"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

main() {
  # 解析引擎选择后再打印标题，避免无参数运行时标题引擎为空。
  resolve_engine 1
  adopt_existing_engine_from_config

  echo ""
  echo "========================================"
  echo "  vLLM 一键安装配置脚本"
  echo "  引擎: ${ENGINE}"
  echo "========================================"
  echo ""
  
  detect_os
  if [[ "$ENGINE_USER_SET" != "true" ]]; then
    case "$ENGINE" in
      vllm-metal) info "检测到 Apple Silicon, 自动选择引擎: ${GREEN}vllm-metal${NC}" ;;
      vllm-mlx) info "检测到 Apple Silicon, 自动选择引擎: ${GREEN}vllm-mlx${NC}" ;;
      vllm) info "自动选择引擎: ${GREEN}vllm${NC}" ;;
    esac
  fi
  detect_hardware
  load_whichllm_recommendations
  if [[ "${MODEL_USER_SET}" != "true" ]] && [[ "${LIST_MODELS}" != "true" ]] && [[ -z "${DOWNLOAD_ONLY_MODEL}" ]]; then
    print_whichllm_summary
  fi

  check_hardware_requirements

  print_runtime_tradeoffs

  if [[ "${VLLM_SKIP_SYSTEM_OPTIMIZE:-0}" != "1" ]]; then
    optimize_macos_system_limits
  fi

  reclaim_memory_if_tight

  # 如果有推荐模型且用户未指定，使用推荐模型
  if [[ -n "$RECOMMENDED_MODELS" ]] && [[ "$DEFAULT_MODEL" == "Qwen/Qwen2.5-32B-Instruct" ]]; then
    # 如果默认模型不适合当前硬件，使用推荐模型
    if [[ "$GPU_TYPE" == "cpu" ]] || [[ "$GPU_MEMORY_GB" -le 6 && "$GPU_MEMORY_GB" -gt 0 ]]; then
      info "根据硬件配置，已将默认模型调整为: ${RECOMMENDED_MODELS}"
      DEFAULT_MODEL="$RECOMMENDED_MODELS"
    fi
  fi
  
  check_python
  
  # 检查是否已安装并检测更新
  local is_upgrade=false
  local already_current=false
  local is_existing_install=false
  local update_applied=false
  local update_skipped_platform=false
  local install_check_status=0
  check_existing_installation || install_check_status=$?
  case "$install_check_status" in
    0) is_upgrade=true; is_existing_install=true ;;
    2) already_current=true; is_existing_install=true ;;
    *) is_upgrade=false ;;
  esac
  # 缓存命中：远端最新版在本平台无可用 wheel，按"平台跳过更新"处理（不重复尝试安装）
  if $UPDATE_PLATFORM_BLOCKED; then
    update_skipped_platform=true
  fi
  if $is_existing_install; then
    load_existing_runtime_config
  fi
  
  # 如果是升级/重新安装，跳过依赖安装（虚拟环境已存在）
  if ! $is_upgrade && ! $already_current || [[ ! -d "${VENV_DIR}" ]]; then
    install_dependencies
    
    # 存储优化 (针对大容量外部磁盘)
    optimize_storage
    
    create_directories
    create_venv
  else
    info "使用已存在的虚拟环境"
    source "${VENV_DIR}/bin/activate"
  fi
  
  if $already_current; then
    if $update_skipped_platform; then
      warn "保持当前已安装版本：最新版在本平台暂不可安装（缺少 wheel），继续执行模型选择与配置检查。"
    else
      info "${ENGINE} 已安装且为最新版本，继续执行模型选择与配置检查。"
    fi
  else
    local install_engine_status=0
    install_engine || install_engine_status=$?
    if [[ "$install_engine_status" == "42" && "$is_existing_install" == "true" ]]; then
      restore_venv_backup
      if [[ -n "$LATEST_REMOTE_PACKAGE" && -n "$LATEST_REMOTE_VERSION" ]]; then
        remember_blocked_update "$LATEST_REMOTE_PACKAGE" "$LATEST_REMOTE_VERSION"
      fi
      warn "自动更新跳过：远端最新版本当前无法在本机平台安装，继续使用已安装版本。"
      update_skipped_platform=true
    elif [[ "$install_engine_status" != "0" ]]; then
      restore_venv_backup
      error "${ENGINE} 安装/更新失败。"
      exit "$install_engine_status"
    else
      discard_venv_backup
      if $is_upgrade; then
        update_applied=true
      fi
    fi
  fi

  if [[ -n "$DOWNLOAD_ONLY_MODEL" ]]; then
    download_model "$DOWNLOAD_ONLY_MODEL"
    success "模型下载完成: $(resolve_model_alias "$DOWNLOAD_ONLY_MODEL")"
    exit 0
  fi

  ensure_default_model

  generate_config
  generate_no_think_chat_template
  generate_scripts

  # 自动启动服务：检测已存在则跳过/询问覆盖
  local existing_service=""
  if [[ "$OS" == "macos" && -f "$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist" ]]; then
    existing_service="$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"
  elif [[ "$OS" == "linux" && -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    existing_service="/etc/systemd/system/${SERVICE_NAME}.service"
  fi

  echo ""
  if [[ -n "$existing_service" ]]; then
    info "已存在自启动服务: ${existing_service}"
    if $update_skipped_platform; then
      # 更新因平台依赖跳过：不重装，但若服务未运行仍应把它拉起来，避免"未运行"状态
      if service_running_hint; then
        info "更新已跳过（平台不兼容），现有服务正在运行，保持不变。"
      else
        warn "更新因平台依赖不兼容而跳过；检测到服务未运行，使用现有版本自动启动。"
        if ! observe_service_startup; then
          warn "服务启动失败，请查看日志。"
        fi
      fi
    elif $update_applied; then
      success "${ENGINE} 已更新到最新版本，自动重启服务使更新生效。"
      if ! observe_service_startup; then
        warn "服务重启后未能正常就绪，请查看日志。"
      fi
    elif $already_current; then
      if ! service_running_hint; then
        info "${ENGINE} 已安装且为最新版本，但服务未运行，自动启动。"
        if ! observe_service_startup; then
          warn "服务启动失败，请查看日志。"
        fi
      else
        if $ASSUME_YES; then
          info "配置可能已更新，自动重启服务以应用新配置。"
          if ! observe_service_startup; then
            warn "服务重启失败，请查看日志。"
          fi
        else
          info "${ENGINE} 已安装且为最新版本，服务已在运行，跳过重启。"
        fi
      fi
    elif $ASSUME_YES; then
      info "自动确认模式，覆盖现有自启动服务。"
      if ! observe_service_startup; then
        warn "自动启动失败，请查看日志。"
      fi
    elif confirm "是否用新配置覆盖? (n=保留现有)" "n"; then
      if ! observe_service_startup; then
        warn "启动失败，请查看日志。"
      fi
    else
      info "已保留现有自启动服务，未做修改。"
    fi
  else
    info "自动启动服务说明:"
    warn "开机自启动会在登录后自动加载模型，占用大量统一内存/显存。专用推理主机可启用，日常工作机建议手动启动。"
    if $is_upgrade || $already_current; then
      info "未检测到自启动服务，自动启动一次并创建服务。"
      if ! observe_service_startup; then
        warn "自动启动失败，请查看日志。"
      fi
    elif $ASSUME_YES; then
      info "自动确认模式，配置开机/自动启动服务。"
      if ! observe_service_startup; then
        warn "自动启动失败，请查看日志。"
      fi
    elif confirm "是否配置开机/自动启动服务" "n"; then
      if ! observe_service_startup; then
        warn "自动启动失败，请查看日志。"
      fi
    else
      info "已跳过自动启动。需要时可执行安装目录中的启动脚本手动启动。"
    fi
  fi

  print_usage
}

# 执行
main "$@"
