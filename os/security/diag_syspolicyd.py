#!/usr/bin/env python3
# diag_syspolicyd.py — macOS syspolicyd 高负载诊断快照 (Python 快速版)
# 为什么用 Python: 系统高负载时 bash 子进程启动慢、log show 会超时;
#                  Python 直读 sysctl/ps 秒级完成, 高负载下也能快速出结果。
# 用途: 采集 syspolicyd CPU/线程/日志/loadavg/swap 快照, 重启前后对比验证。
# 用法: python3 diag_syspolicyd.py [label]   # label 默认 BEFORE/AFTER
import subprocess, os, sys, datetime

LABEL = sys.argv[1] if len(sys.argv) > 1 else datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
OUT = os.path.expanduser("~/syspolicyd_diag")
os.makedirs(OUT, exist_ok=True)
SNAP = os.path.join(OUT, f"snapshots-{LABEL}.txt")

def run(cmd, timeout=45):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.stdout or r.stderr).strip()
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    except Exception as e:
        return f"ERR {e}"

L = []
L.append("="*60)
L.append(f"  syspolicyd 诊断快照  label={LABEL}")
L.append(f"  时间: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
L.append("="*60)
L.append("\n### 1. 系统负载")
L.append(f"  loadavg: {run(['sysctl','-n','vm.loadavg'])}")
L.append(f"  CPU核: {run(['sysctl','-n','hw.ncpu'])}")

spid = run(["pgrep","-x","syspolicyd"])
L.append(f"\n### 2. syspolicyd pid={spid or '未找到'}")
if spid:
    sp = spid.split()[0]
    L.append(f"  {run(['ps','-o','pid=,stat=,pcpu=,pmem=,etime=','-p',sp])}")
    L.append("  线程 (UTIME=累计CPU秒):")
    for l in (run(["ps","-M","-p",sp]) or "").split("\n"):
        if l.strip(): L.append("    "+l.strip()[:100])

L.append("\n### 3. top CPU (排除 syspolicyd)")
for l in (run(["ps","-Ao","pid=,pcpu=,comm=","-r"]) or "").split("\n")[:8]:
    if l.strip() and "syspolicyd" not in l: L.append("  "+l.strip()[:80])

L.append("\n### 4. swap")
L.append(f"  {run(['sysctl','-n','vm.swapusage'])}")

L.append("\n### 5. failed to call driver (最近 20 分钟)")
log = run(["log","show","--last","20m","--predicate",
    'process == "syspolicyd" AND eventMessage CONTAINS "failed to call driver"',
    "--style","compact"])
cnt = log.count("failed to call driver") if log != "TIMEOUT" else "TIMEOUT"
L.append(f"  条数: {cnt}")

L.append("\n### 6. 判定")
if spid:
    cpu = run(["ps","-o","pcpu=","-p",spid.split()[0]]).strip()
    try:
        ci = int(float(cpu))
    except: ci = 0
    if ci > 50: L.append(f"  [高负载] CPU={cpu}% (>50%) 死循环持续")
    elif ci > 10: L.append(f"  [中等] CPU={cpu}%")
    else: L.append(f"  [正常] CPU={cpu}% 已回落")
else:
    L.append("  [未运行]")

with open(SNAP, "w") as f:
    f.write("\n".join(L)+"\n")
print(f"OK: {SNAP}")
print(f"判定: {L[-1]}")
