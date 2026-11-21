#!/system/bin/sh
# 卸载模块：停掉守护进程（保留 /data/adb/acc_keeper 里的配置与日志，方便回看）
DATA_DIR=/data/adb/acc_keeper
PID_FILE=$DATA_DIR/daemon.pid

if [ -f "$PID_FILE" ]; then
  pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -f "$PID_FILE"
fi

# 兜底：扫描 /proc 清理所有 acc_keeper.sh 进程
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q 'acc_keeper.sh'; then
    kill "${d#/proc/}" 2>/dev/null
  fi
done
exit 0
