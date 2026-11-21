#!/system/bin/sh
# 开机后（late_start service 阶段）拉起守护进程
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/acc_keeper

# 用子 shell 后台跑，避免阻塞 KernelSU 的启动流程
(
  i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 180 ]; do
    sleep 1
    i=$((i + 1))
  done
  sleep 2
  exec sh "$MODDIR/bin/acc_keeper.sh"
) >/dev/null 2>&1 &
