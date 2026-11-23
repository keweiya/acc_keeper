#!/system/bin/sh
# ==========================================================
#  安装脚本（KernelSU / KernelSU Next / Magisk 都会执行）
# ==========================================================
if ! type ui_print >/dev/null 2>&1; then
  ui_print() { echo "$1"; }
fi
if [ -z "$MODPATH" ]; then
  MODPATH=${0%/*}
fi

DATA_DIR=/data/adb/acc_keeper
ui_print "- 安装 无障碍守护 (acc_keeper)"

umask 077
mkdir -p "$DATA_DIR/logs" "$DATA_DIR/state" "$DATA_DIR/locks"
chmod 700 "$DATA_DIR/logs" "$DATA_DIR/state" "$DATA_DIR/locks" 2>/dev/null
chmod 700 "$DATA_DIR" 2>/dev/null

# 保留已有配置，只在缺失时写入默认值
if [ ! -f "$DATA_DIR/targets.txt" ]; then
  cp -f "$MODPATH/config/targets.txt" "$DATA_DIR/targets.txt" 2>/dev/null
  ui_print "- 已生成默认 targets.txt"
fi
if [ ! -f "$DATA_DIR/settings.conf" ]; then
  cp -f "$MODPATH/config/settings.conf" "$DATA_DIR/settings.conf" 2>/dev/null
fi

chmod 755 "$MODPATH/service.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/uninstall.sh" "$MODPATH/action.sh" 2>/dev/null
chmod 755 "$MODPATH/bin/acc_keeper.sh" "$MODPATH/bin/acc_ctl" 2>/dev/null
chmod 644 "$MODPATH/bin/acc_runtime.sh" 2>/dev/null
chmod 755 "$MODPATH/system/bin/acc_ctl" 2>/dev/null
chmod 644 "$DATA_DIR/targets.txt" "$DATA_DIR/settings.conf" 2>/dev/null

ui_print "- 配置目录: /data/adb/acc_keeper"
ui_print "- 重启后守护进程自动启动；点检或 Action 也会检查并拉起"
ui_print "- 配置方法: su -c acc_ctl scan / add <包名>"
