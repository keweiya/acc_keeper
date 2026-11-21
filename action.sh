#!/system/bin/sh
# ==========================================================
#  KernelSU 模块卡片上的「操作」按钮（ksud module action acc_keeper）
#  跑一轮立即检查，打印几行结果
# ==========================================================
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/acc_keeper

echo "无障碍守护 · 立即检查"
echo "------------------------"

if [ -f "$MODDIR/bin/acc_ctl" ]; then
  /system/bin/sh "$MODDIR/bin/acc_ctl" check
else
  echo "模块文件不完整：找不到 bin/acc_ctl"
fi
