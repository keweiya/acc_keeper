# acc_keeper 的进程身份和文件锁。由 acc_ctl / acc_keeper.sh source。
# 始终用 boot_id + /proc 起始时刻 + 精确 argv 校验，禁止按未经验证的 PID 发信号。

# ---------------------------------------------------------------- 数据目录布局
# 根目录只保留用户文件：settings.conf / targets.txt
#   logs/   当前开机周期的日志（设备重启时清空重建）
#   state/  pid、计数、上次退出、失败节流、拒绝名单、暂停与 stop 标记
#   locks/  flock 锁文件
ACC_LOG_DIR=$DATA_DIR/logs
ACC_STATE_DIR=$DATA_DIR/state
ACC_LOCK_DIR=$DATA_DIR/locks

# 建目录并把旧版平铺布局搬到新位置。幂等：旧文件不在就什么都不做。
acc_init_layout() {
  # 运行时目录只给 root：默认 umask 可能是 000，mkdir 会建出 777
  _acc_old_umask=$(umask)
  umask 077
  mkdir -p "$ACC_LOG_DIR" "$ACC_STATE_DIR" "$ACC_LOCK_DIR" 2>/dev/null || { umask "$_acc_old_umask"; return 1; }
  chmod 700 "$ACC_LOG_DIR" "$ACC_STATE_DIR" "$ACC_LOCK_DIR" 2>/dev/null
  umask "$_acc_old_umask"
  [ -f "$DATA_DIR/acc_keeper.log" ] && mv -f "$DATA_DIR/acc_keeper.log" "$ACC_LOG_DIR/acc_keeper.log" 2>/dev/null
  for acc_lf in daemon.pid last_good ticks.count fixes.count rejected.txt paused; do
    [ -f "$DATA_DIR/$acc_lf" ] && mv -f "$DATA_DIR/$acc_lf" "$ACC_STATE_DIR/$acc_lf" 2>/dev/null
  done
  [ -f "$DATA_DIR/.last_boot" ] && mv -f "$DATA_DIR/.last_boot" "$ACC_STATE_DIR/last_boot" 2>/dev/null
  [ -f "$DATA_DIR/.last_exit" ] && mv -f "$DATA_DIR/.last_exit" "$ACC_STATE_DIR/last_exit" 2>/dev/null
  [ -f "$DATA_DIR/.last_fail" ] && mv -f "$DATA_DIR/.last_fail" "$ACC_STATE_DIR/last_fail" 2>/dev/null
  [ -f "$DATA_DIR/.stop" ] && mv -f "$DATA_DIR/.stop" "$ACC_STATE_DIR/stop" 2>/dev/null
  for acc_lk in daemon work lifecycle; do
    [ -f "$DATA_DIR/.$acc_lk.lock" ] && mv -f "$DATA_DIR/.$acc_lk.lock" "$ACC_LOCK_DIR/$acc_lk.lock" 2>/dev/null
  done
  return 0
}

ACC_LOCK_TOOL=
acc_lock_init() {
  [ -n "$ACC_LOCK_TOOL" ] && return 0
  # Android shell 对 exec N> 设置 CLOEXEC，不能用 flock FD；使用 busybox flock FILE PROG。
  for acc_lt in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox busybox; do
    if [ "$acc_lt" = busybox ]; then
      command -v busybox >/dev/null 2>&1 || continue
    else
      [ -x "$acc_lt" ] || continue
    fi
    # 能力探测独立命名，避免并发请求误判 busybox 不支持 flock。
    acc_probe="$ACC_LOCK_DIR/.flock-probe.$$"
    if "$acc_lt" flock -n "$acc_probe" true 2>/dev/null; then
      rm -f "$acc_probe" 2>/dev/null
      ACC_LOCK_TOOL=$acc_lt
      return 0
    fi
    rm -f "$acc_probe" 2>/dev/null
  done
  return 1
}
# Busybox flock 进程创建锁 FD 后 exec 目标，通常为 3；主动关闭锁描述符，
# 防止 settings/sleep 等外部命令继承并在守护退出后继续占锁。
# 调用时固定从 fd 3 开始，脚本自身不使用这些描述符。
acc_close_lock_fd() {
  acc_lock_path=$1
  for acc_fd in 3 4 5 6 7 8 9; do
    acc_fd_path=$(readlink "/proc/$$/fd/$acc_fd" 2>/dev/null)
    # PRoot 对 /proc/PID/fd 的 readlink 可能截断到 32 字节；优先精确匹配。
    # 截断情形下只接受绝对路径前缀，避开 pipe/socket/普通描述符。
    case "$acc_fd_path" in
      '') continue ;;
      "$acc_lock_path") eval "exec $acc_fd>&-"; return 0 ;;
      /*) case "$acc_lock_path" in
            "$acc_fd_path"*)
              [ "${#acc_fd_path}" -ge 32 ] || continue
              eval "exec $acc_fd>&-"; return 0 ;;
          esac ;;
    esac
  done
  return 1
}

acc_proc_start() {
  case "$1" in ''|0|*[!0-9]*) return 1 ;; esac
  acc_stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  # comm 可以包含空格或右括号；去掉最后一个 ") " 后字段 20 即 starttime。
  case "$acc_stat" in *') '*) acc_stat=${acc_stat##*) } ;; *) return 1 ;; esac
  set -- $acc_stat
  [ "$#" -ge 20 ] || return 1
  case "$1" in Z|X|x) return 1 ;; esac
  shift 19
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$1"
}

acc_pid_identity() {
  acc_id_pid=$1
  acc_id_start=$2
  acc_id_boot=$3
  case "$acc_id_pid" in ''|0|*[!0-9]*) return 1 ;; esac
  case "$acc_id_start" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$acc_id_boot" ] || return 1
  [ "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" = "$acc_id_boot" ] || return 1
  [ "$(acc_proc_start "$acc_id_pid")" = "$acc_id_start" ] || return 1
  # /proc 也允许按线程 ID 访问；只接受线程组首领 PID。
  acc_tgid=$(sed -n 's/^Tgid:[[:space:]]*//p' "/proc/$acc_id_pid/status" 2>/dev/null)
  [ "$acc_tgid" = "$acc_id_pid" ] || return 1
  # 新版带 --daemon；旧版开机/acc_ctl 启动的 shell 无参数。
  # 严格匹配完整 argv，拒绝 --once/--desc/检查脚本与其他进程。
  acc_id_args=$(tr '\000' '\n' < "/proc/$acc_id_pid/cmdline" 2>/dev/null) || return 1
  case "$acc_id_args" in
    "sh
$MODDIR/bin/acc_keeper.sh
--daemon"|"/system/bin/sh
$MODDIR/bin/acc_keeper.sh
--daemon"|"/bin/sh
$MODDIR/bin/acc_keeper.sh
--daemon"|"sh
$MODDIR/bin/acc_keeper.sh"|"/system/bin/sh
$MODDIR/bin/acc_keeper.sh"|"/bin/sh
$MODDIR/bin/acc_keeper.sh") ;;
    *) return 1 ;;
  esac
  # 读取 cmdline 时 PID 可能被复用，再核一次 starttime。
  [ "$(acc_proc_start "$acc_id_pid")" = "$acc_id_start" ]
}

acc_running() {
  ACC_PID=; ACC_START=; ACC_BOOT=
  [ -r "$PID_FILE" ] || return 1
  IFS=' ' read -r ACC_PID ACC_START ACC_BOOT acc_extra < "$PID_FILE" || return 1
  [ -z "$acc_extra" ] || return 1
  # 迁移旧 PID 单字段格式：只在目标 argv 是无参数的旧版 daemon 时允许。
  if [ -z "$ACC_START" ] && [ -z "$ACC_BOOT" ]; then
    ACC_START=$(acc_proc_start "$ACC_PID") || return 1
    ACC_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
    acc_pid_identity "$ACC_PID" "$ACC_START" "$ACC_BOOT" || return 1
    acc_legacy_args=$(tr '\000' '\n' < "/proc/$ACC_PID/cmdline" 2>/dev/null) || return 1
    case "$acc_legacy_args" in
      "sh
$MODDIR/bin/acc_keeper.sh"|"/system/bin/sh
$MODDIR/bin/acc_keeper.sh"|"/bin/sh
$MODDIR/bin/acc_keeper.sh") return 0 ;;
      *) return 1 ;;
    esac
  fi
  acc_pid_identity "$ACC_PID" "$ACC_START" "$ACC_BOOT"
}

acc_write_identity() {
  acc_self_start=$(acc_proc_start "$$") || return 1
  acc_self_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || return 1
  [ -n "$acc_self_boot" ] || return 1
  acc_pid_identity "$$" "$acc_self_start" "$acc_self_boot" || return 1
  ACC_SELF_ID="$$ $acc_self_start $acc_self_boot"
  acc_tmp="$PID_FILE.tmp.$$"
  umask 077
  printf '%s\n' "$ACC_SELF_ID" > "$acc_tmp" && mv -f "$acc_tmp" "$PID_FILE" || { rm -f "$acc_tmp"; return 1; }
  return 0
}

acc_cleanup_identity() {
  # 只删除自己的身份记录；不能删除后继实例。
  [ -n "${ACC_SELF_ID:-}" ] || return 0
  acc_record=$(cat "$PID_FILE" 2>/dev/null)
  [ "$acc_record" = "$ACC_SELF_ID" ] && rm -f "$PID_FILE" 2>/dev/null
}

acc_is_paused() {
  acc_exp=$(cat "$PAUSE_FILE" 2>/dev/null)
  case "$acc_exp" in ''|*[!0-9]*) return 1 ;; esac
  acc_now=$(date +%s)
  [ "$acc_exp" -gt "$acc_now" ]
}

# 调用方在 busybox flock FILE 包装进程下运行，确保原子启动。
acc_ensure_started() {
  # _ensure_locked 是独立 shell，父进程选定的变量不会自动继承。
  acc_lock_init || return 1
  ACC_START_RESULT=already
  if acc_running && [ ! -e "$ACC_STATE_DIR/stop" ]; then return 0; fi
  if acc_running; then
    acc_tries=0
    while acc_running; do
      [ "$acc_tries" -ge 100 ] && return 1
      sleep 0.2; acc_tries=$((acc_tries + 1))
    done
  fi
  # 等旧 flock wrapper 完整退出，不在此处清除 .stop；PID 不可作为锁的替代。
  acc_tries=0
  while ! "$ACC_LOCK_TOOL" flock -n "$ACC_LOCK_DIR/daemon.lock" true 2>/dev/null; do
    [ "$acc_tries" -ge 40 ] && return 1
    sleep 0.2; acc_tries=$((acc_tries + 1))
  done
  # 启动子进程先关闭 lifecycle FD，再 exec，避免额外常驻 shell 或泄漏锁。
  (
    acc_close_lock_fd "$ACC_LOCK_DIR/lifecycle.lock" || exit 1
    exec sh "$MODDIR/bin/acc_keeper.sh"
  ) </dev/null >/dev/null 2>&1 &
  acc_tries=0
  while [ "$acc_tries" -lt 50 ]; do
    if acc_running && [ ! -e "$ACC_STATE_DIR/stop" ]; then
      ACC_START_RESULT=started
      return 0
    fi
    sleep 0.2; acc_tries=$((acc_tries + 1))
  done
  return 1
}
