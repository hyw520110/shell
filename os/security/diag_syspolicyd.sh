#!/bin/bash
# diag_syspolicyd.sh — macOS syspolicyd 高负载诊断快照脚本
# 用途: 采集 syspolicyd CPU/线程/日志/loadavg/内存快照，重启前后对比验证是否回落。
# 用法: sudo ./diag_syspolicyd.sh [label]
#   label 默认 = 当前时间戳。重启前跑一次（BEFORE），重启后跑一次（AFTER）。
#   每份快照存到 ~/syspolicyd_diag/snapshots-<label>.txt，对比判定行即可。
# 背景: syspolicyd 因 Gatekeeper 驱动调用失败（failed to call driver: 0x3）陷入
#       4线程忙等死循环（各 ~85% CPU）。此脚本固化证据，重启后验证是否自愈。

set -uo pipefail

LABEL="${1:-$(date '+%Y%m%d_%H%M%S')}"
OUT_DIR="$HOME/syspolicyd_diag"
SNAP="$OUT_DIR/snapshots-${LABEL}.txt"
mkdir -p "$OUT_DIR"

SPID=$(pgrep -x syspolicyd | head -1)

{
  echo "=============================================================="
  echo "  syspolicyd 诊断快照  label=$LABEL"
  echo "  时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "=============================================================="

  echo
  echo "### 1. 系统负载 (loadavg 1/5/15) + CPU 核心数"
  sysctl -n vm.loadavg 2>/dev/null | awk -v t="$(date '+%H:%M:%S')" '{print "  ["t"] " $0}'
  sysctl -n hw.ncpu 2>/dev/null | sed 's/^/  CPU核心数: /'

  echo
  echo "### 2. syspolicyd 进程 (pid=${SPID:-未找到})"
  if [ -n "$SPID" ]; then
    ps -o pid=,stat=,pcpu=,pmem=,etime= -p "$SPID" 2>/dev/null | sed 's/^/  /'
    echo "  线程明细 (UTIME=累计CPU秒, 越大越忙):"
    ps -M -p "$SPID" 2>/dev/null | sed 's/^/    /'
  else
    echo "  [未找到 syspolicyd 进程 — 已自愈或被停止]"
  fi

  echo
  echo "### 3. top 8 CPU 进程 (排除 syspolicyd)"
  ps -Ao pid=,pcpu=,pmem=,comm= -r 2>/dev/null | grep -v syspolicyd | head -8 | sed 's/^/  /'

  echo
  echo "### 4. 内存 / swap 压力"
  vm_stat 2>/dev/null | grep -E "Pages free|Pages inactive|Pages occupied by compressor|Swapins|Swapouts" | sed 's/^/  /'
  sysctl -n vm.swapusage 2>/dev/null | sed 's/^/  /'

  echo
  echo "### 5. syspolicyd 'failed to call driver' 日志 (最近 20 分钟)"
  LOG=$(log show --last 20m --predicate 'process == "syspolicyd" AND eventMessage CONTAINS "failed to call driver"' --style compact 2>/dev/null)
  COUNT=$(echo "$LOG" | grep -c "failed to call driver" || echo 0)
  echo "  条数: $COUNT"
  if [ "$COUNT" -gt 0 ]; then
    echo "  时间分布 (分钟: 条数):"
    echo "$LOG" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' \
      | sort | uniq -c | sed 's/^/    /' | head -30
  fi

  echo
  echo "### 6. syspolicyd 最近 60s 日志活动量"
  ACTIVE=$(log show --last 60s --predicate 'process == "syspolicyd"' --style compact 2>/dev/null | grep -cE 'syspolicyd\[' || echo 0)
  echo "  60s 内日志行数: $ACTIVE"

  echo
  echo "### 7. 总结判定"
  if [ -n "$SPID" ]; then
    CPU=$(ps -o pcpu= -p "$SPID" 2>/dev/null | tr -d ' ')
    CPU_INT=${CPU%.*}; CPU_INT=${CPU_INT:-0}
    if   [ "$CPU_INT" -gt 50 ]; then echo "  [高负载] syspolicyd CPU=${CPU}% (>50%) — 死循环/忙等持续"
    elif [ "$CPU_INT" -gt 10 ]; then echo "  [中等]   syspolicyd CPU=${CPU}% (10-50%) — 仍活动但非峰值"
    else echo "  [正常]   syspolicyd CPU=${CPU}% (≤10%) — 已回落/自愈"
    fi
  else
    echo "  [未运行] syspolicyd 进程不存在 — 已停止"
  fi
  echo
  echo "  快照: $SNAP"
} > "$SNAP" 2>&1

echo "OK: $SNAP"
echo "对比: 重启后跑  sudo ./diag_syspolicyd.sh AFTER  然后对比 BEFORE/AFTER 的 [7] 判定行"
