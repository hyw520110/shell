#!/usr/bin/env bash
# =============================================================================
# mount-all.sh - 自动挂载所有数据分区（读写）【通用版】
# -----------------------------------------------------------------------------
# 通用性: 任何 Linux（systemd + lsblk + util-linux）可用，不依赖具体发行版。
#   - 动态扫描全部磁盘分区，无需改配置即可跨机器复用
#   - 按 UUID 挂载（盘符漂移不受影响）
#   - 自动跳过: 根分区 / swap / 无文件系统 / 已挂载 / 光驱 / 1K 扩展分区
#   - NTFS: 内核 ntfs3 优先，失败自动回退 ntfs-3g（fstab 写入实际可用类型）
#   - 挂载点 /mnt/<LABEL 或 sdaX>；LABEL 特殊字符自动清理
# -----------------------------------------------------------------------------
# 用法:
#   sudo ./mount-all.sh             # 挂载全部未挂载分区
#   sudo ./mount-all.sh --fstab     # 挂载 + 写入 /etc/fstab（开机自动挂载）
#   sudo ./mount-all.sh --list      # 只列出将要挂载的分区，不执行
# =============================================================================

set -uo pipefail

MODE="mount"          # mount | fstab | list
DO_FSTAB=0
SUDO="sudo"
[ "$(id -u)" = "0" ] && SUDO=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error(){ echo -e "${RED}[ERR ]${NC}  $*" >&2; }

# 参数解析
for a in "$@"; do
  case "$a" in
    --fstab) DO_FSTAB=1 ;;
    --list)  MODE="list" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) error "未知参数: $a"; exit 2 ;;
  esac
done

UID_NUM="$(id -u "$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")" 2>/dev/null || echo 1000)"
GID_NUM="$(id -g "$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")" 2>/dev/null || echo 1000)"
ROOT_PART="$(findmnt -n -o SOURCE / 2>/dev/null | sed 's|.*/||')"

fs_opts() {  # $1=fstype → 挂载参数
  case "$1" in
    ntfs|ntfs3|ntfs-3g) echo "defaults,uid=${UID_NUM},gid=${GID_NUM},umask=022,noatime" ;;
    vfat|exfat) echo "defaults,uid=${UID_NUM},gid=${GID_NUM},umask=022" ;;
    ext4|ext3|ext2|btrfs|xfs) echo "defaults,noatime" ;;
    *) echo "defaults" ;;
  esac
}

# NTFS 实际可用的挂载类型: 有 ntfs-3g(fuse) 用 ntfs-3g（兼容性最广），否则 ntfs3（内核）
ntfs_fstype() {
  if command -v ntfs-3g >/dev/null 2>&1; then echo "ntfs-3g"; else echo "ntfs3"; fi
}

mount_one() {  # $1=device $2=fstype $3=mountpoint
  local dev="$1" fstype="$2" mp="$3"
  if [ ! -d "$mp" ]; then
    $SUDO mkdir -p "$mp" || { error "创建挂载点失败: $mp"; return 1; }
  fi
  local opts
  opts="$(fs_opts "$fstype")"
  if [ "$fstype" = "ntfs" ]; then
    local ntfs_type
    ntfs_type="$(ntfs_fstype)"
    if $SUDO mount -t "$ntfs_type" -o "$opts" "$dev" "$mp" 2>/dev/null; then
      ok "挂载 $dev → $mp ($ntfs_type, rw)"
      return 0
    fi
    # 回退另一实现（ntfs-3g ↔ ntfs3）
    if [ "$ntfs_type" = "ntfs-3g" ]; then
      $SUDO mount -t ntfs3 -o "$opts" "$dev" "$mp" 2>/dev/null && { ok "挂载 $dev → $mp (ntfs3, rw)"; return 0; }
    else
      command -v ntfs-3g >/dev/null 2>&1 && $SUDO mount -t ntfs-3g -o "$opts" "$dev" "$mp" 2>/dev/null && { ok "挂载 $dev → $mp (ntfs-3g, rw)"; return 0; }
    fi
    error "$dev 挂载失败（ntfs3 与 ntfs-3g 均不可用，建议: apt install ntfs-3g）"
    return 1
  fi
  if $SUDO mount -t "$fstype" -o "$opts" "$dev" "$mp"; then
    ok "挂载 $dev → $mp ($fstype, rw)"
    return 0
  fi
  error "$dev 挂载失败"
  return 1
}

# ---------------------------------------------------------------------------
# 扫描 & 主流程
# ---------------------------------------------------------------------------
info "用户 uid/gid: ${UID_NUM}/${GID_NUM}，根分区: ${ROOT_PART:-未知}"
[ "$MODE" = "list" ] && info "以下分区将挂载（读写）:"
COUNT=0

declare -a PENDING_DEVS=() PENDING_FS=() PENDING_MP=()

while read -r name fstype label mp; do
  # 跳过: 无文件系统 / 光驱 / 根分区 / swap / 已挂载 / 根挂载点
  [ -z "$fstype" ] && continue
  case "$name" in sr*) continue ;; esac
  [ "$name" = "$ROOT_PART" ] && continue
  [ "$fstype" = "swap" ] && continue
  [ "$mp" = "/" ] && continue
  [ -n "$mp" ] && continue

  dev="/dev/$name"
  if [ "$fstype" = "ntfs" ] || [ "$fstype" = "ntfs3" ]; then fs="ntfs"; else fs="$fstype"; fi

  # 挂载点命名: 有 LABEL 用 LABEL（清理特殊字符），否则 sdaX
  if [ -n "$label" ] && [ "$label" != "-" ]; then
    mpoint="/mnt/$(echo "$label" | tr ' /\\:' '____')"
  else
    mpoint="/mnt/${name}"
  fi

  # 挂载点已被占用则跳过（防冲突）
  if findmnt -n "$mpoint" >/dev/null 2>&1; then
    warn "$mpoint 已被占用，跳过 $dev"
    continue
  fi

  if [ "$MODE" = "list" ]; then
    info "  $dev ($fs, LABEL=${label:--}) → $mpoint"
    COUNT=$((COUNT+1))
  else
    PENDING_DEVS+=("$dev"); PENDING_FS+=("$fs"); PENDING_MP+=("$mpoint")
  fi
done < <(lsblk -n -r -o NAME,FSTYPE,LABEL,MOUNTPOINTS 2>/dev/null)

if [ "$MODE" = "list" ]; then
  echo ""
  info "共 $COUNT 个分区将挂载（--list 模式下未执行挂载）"
  exit 0
fi

if [ "${#PENDING_DEVS[@]}" -eq 0 ]; then
  ok "所有数据分区已挂载，无需操作"
  exit 0
fi

for i in "${!PENDING_DEVS[@]}"; do
  mount_one "${PENDING_DEVS[$i]}" "${PENDING_FS[$i]}" "${PENDING_MP[$i]}" || true
done

# ---------------------------------------------------------------------------
# --fstab: 写入开机自动挂载（幂等）
# ---------------------------------------------------------------------------
if [ "$DO_FSTAB" = "1" ]; then
  echo ""
  info "写入 /etc/fstab 开机自动挂载..."
  for i in "${!PENDING_DEVS[@]}"; do
    dev="${PENDING_DEVS[$i]}"; fs="${PENDING_FS[$i]}"; mp="${PENDING_MP[$i]}"
    uuid="$(lsblk -n -o UUID "$dev" 2>/dev/null)"
    [ -z "$uuid" ] && { warn "$dev 无 UUID，跳过 fstab 写入"; continue; }
    # NTFS 必须写实际可用类型（ntfs-3g 优先/ntfs3），写 "ntfs" 会挂载失败
    local_fs="$fs"
    [ "$local_fs" = "ntfs" ] && local_fs="$(ntfs_fstype)"
    line="UUID=${uuid} ${mp} ${local_fs} $(fs_opts "$local_fs") 0 0"
    if grep -q "UUID=${uuid}" /etc/fstab 2>/dev/null; then
      ok "fstab 已存在: $dev ($mp)"
    else
      echo "$line" | $SUDO tee -a /etc/fstab >/dev/null && ok "fstab 追加: $dev → $mp ($local_fs)"
    fi
  done
  echo ""
  info "fstab 写入完成，重启后自动挂载（可先: sudo mount -a 验证）"
fi

echo ""
ok "完成！挂载点列表:"
for i in "${!PENDING_MP[@]}"; do
  if findmnt -n "${PENDING_MP[$i]}" >/dev/null 2>&1; then
    echo "  ${PENDING_MP[$i]}  ←  ${PENDING_DEVS[$i]}"
  else
    warn "  ${PENDING_MP[$i]}  挂载失败（见上方错误）"
  fi
done
