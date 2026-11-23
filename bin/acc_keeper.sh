#!/system/bin/sh
# ==========================================================================
#  Accessibility Keeper —— 无障碍服务守护进程  (KernelSU / KernelSU Next / Magisk)
#
#  运行模式:
#    sh acc_keeper.sh          后台常驻守护（由 service.sh 开机拉起）
#    sh acc_keeper.sh --once   只执行一轮检查/修复后退出（acc_ctl apply 用）
# ==========================================================================
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:/data/adb/ap/bin:$PATH

DATA_DIR=${ACC_KEEPER_DATA_DIR:-/data/adb/acc_keeper}
TARGETS_FILE=$DATA_DIR/targets.txt
CONF_FILE=$DATA_DIR/settings.conf
LOG_FILE=$DATA_DIR/acc_keeper.log
STATE_FILE=$DATA_DIR/last_good
PAUSE_FILE=$DATA_DIR/paused
REJECTED_FILE=$DATA_DIR/rejected.txt
FIXES_FILE=$DATA_DIR/fixes.count
PID_FILE=$DATA_DIR/daemon.pid
TICKS_FILE=$DATA_DIR/ticks.count     # 累计检查次数（跨重启）
BOOT_STATE_FILE=$DATA_DIR/.last_boot # 上次记录到的 boot_id，用来区分"设备重启"和"进程重启"
LAST_EXIT_FILE=$DATA_DIR/.last_exit  # 上一次守护退出的摘要
MAXLOG=1048576        # 日志上限 1MB，超过就滚动保留后半段

MODDIR=${MODDIR:-${ACC_KEEPER_MODDIR:-/data/adb/modules/acc_keeper}}
[ -r "$MODDIR/bin/acc_runtime.sh" ] || exit 1
. "$MODDIR/bin/acc_runtime.sh"
ACC_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
[ -n "$ACC_VERSION" ] || ACC_VERSION="unknown"

# ---- 默认参数，可被 /data/adb/acc_keeper/settings.conf 覆盖 ----
VERBOSE=0              # 1 = 连启动/新增/详细恢复过程都记，默认只记变更与错误
POLL_FAST=3            # 开机初期轮询间隔（秒）
POLL_SLOW=60           # 稳定后轮询间隔（秒）
BOOT_FAST_SECONDS=180  # 开机后多少秒内使用快速轮询
BOOST_TICKS=10         # 修复成功后额外快查的次数
VERIFY_SLEEP=1         # 写完设置后等多久再读回来校验（秒）
STRICT=0               # 兼容旧配置；修复时始终保留非目标服务
HEARTBEAT_SECONDS=1800 # 心跳日志间隔（秒）；0 = 关闭
SLOW_TICK_MS=3000      # 单轮检查超过多少毫秒额外记一条日志

[ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR" 2>/dev/null
if [ -f "$CONF_FILE" ]; then . "$CONF_FILE"; fi
# 配置写错也不能让守护死掉：非数字一律回落到默认值
for _v in POLL_FAST POLL_SLOW BOOT_FAST_SECONDS BOOST_TICKS HEARTBEAT_SECONDS SLOW_TICK_MS; do
  eval "_val=\$$_v"
  case "$_val" in
    ''|*[!0-9]*)
      case "$_v" in
        POLL_FAST) POLL_FAST=3 ;;
        POLL_SLOW) POLL_SLOW=60 ;;
        BOOT_FAST_SECONDS) BOOT_FAST_SECONDS=180 ;;
        BOOST_TICKS) BOOST_TICKS=10 ;;
        HEARTBEAT_SECONDS) HEARTBEAT_SECONDS=1800 ;;
        SLOW_TICK_MS) SLOW_TICK_MS=3000 ;;
      esac ;;
  esac
done
[ "$POLL_FAST" -lt 1 ] && POLL_FAST=1
[ "$POLL_SLOW" -lt 1 ] && POLL_SLOW=1

# ---------------------------------------------------------------- 日志
log() {
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null
  sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
  if [ "${sz:-0}" -gt "$MAXLOG" ]; then
    tail -c $((MAXLOG / 2)) "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
  fi
}

# ---------------------------------------------------------------- 小工具
# 毫秒时间戳（Android toybox date 支持 %3N；万一不支持就退回整秒）
now_ms() {
  _raw=$(date +%s%3N 2>/dev/null)
  case "$_raw" in ''|*[!0-9]*) _raw="" ;; esac
  if [ -z "$_raw" ]; then
    # 完全不支持 %3N 的 date：退回整秒 + 000
    _raw="$(date +%s)000"
  elif [ "${#_raw}" -le 10 ]; then
    # busybox 会忽略 %3N 只输出秒
    _raw="${_raw}000"
  fi
  printf '%s' "$_raw"
}
boot_id_now() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
fmt_dur() {
  _ds=$1
  case "$_ds" in ''|*[!0-9]*) _ds=0 ;; esac
  if [ "$_ds" -ge 86400 ]; then
    printf '%s' "$((_ds / 86400))天$(((_ds % 86400) / 3600))小时"
  elif [ "$_ds" -ge 3600 ]; then
    printf '%s' "$((_ds / 3600))小时$(((_ds % 3600) / 60))分"
  elif [ "$_ds" -ge 60 ]; then
    printf '%s' "$((_ds / 60))分$((_ds % 60))秒"
  else
    printf '%s' "${_ds}秒"
  fi
}
read_ticks() {
  _tk=$(cat "$TICKS_FILE" 2>/dev/null)
  case "$_tk" in ''|*[!0-9]*) _tk=0 ;; esac
  printf '%s' "$_tk"
}
# 组件数量（空输出按 0 算）
count_lines() {
  _cl=$(printf '%s\n' "$1" | grep -c . 2>/dev/null)
  case "$_cl" in ''|*[!0-9]*) _cl=0 ;; esac
  printf '%s' "$_cl"
}

# ------------------------------------------------- 组件名规范化
# com.foo/.Svc 或 com.foo/com.foo.Svc -> 统一输出 com.foo/com.foo.Svc
norm_one() {
  c=$1
  case "$c" in */*) ;; *) return 1 ;; esac
  pkg=${c%%/*}; cls=${c#*/}
  [ -z "$pkg" ] && return 1
  [ -z "$cls" ] && return 1
  case "$cls" in */*) return 1 ;; esac
  case "$cls" in
    .*) cls="$pkg$cls" ;;
    *.*) ;;
    *) cls="$pkg.$cls" ;;
  esac
  printf '%s/%s\n' "$pkg" "$cls"
}

norm_list() {
  printf '%s\n' "$1" | tr -d '\r' | tr ':' '\n' | while IFS= read -r c || [ -n "$c" ]; do
    [ -z "$c" ] && continue
    case "$c" in null|NULL|Null) continue ;; esac
    norm_one "$c" || continue
  done | sort -u
}

read_targets_norm() {
  [ -f "$TARGETS_FILE" ] || return 0
  sed -e 's/#.*//' "$TARGETS_FILE" 2>/dev/null | tr -d ' \t\r' | while IFS= read -r c || [ -n "$c" ]; do
    [ -z "$c" ] && continue
    norm_one "$c" || continue
  done | sort -u
}

# ------------------------------------------- 把当前状态写进 module.prop
# KernelSU 的模块卡片显示的就是 description，所以让它当状态栏用：
#   ● 运行中｜守护 2 个应用｜已恢复 7 次｜每 60 秒巡检
# 累计"恢复次数"：存文件，不受日志滚动/清空影响
read_fixes() {
  _f=$(cat "$FIXES_FILE" 2>/dev/null)
  case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
  printf '%s' "$_f"
}
bump_fixes() {
  _n=$(read_fixes)
  printf '%s' $((_n + 1)) > "$FIXES_FILE" 2>/dev/null
  chmod 600 "$FIXES_FILE" 2>/dev/null
}

update_desc() {
  mp="$MODDIR/module.prop"
  [ -f "$mp" ] || return 0
  [ -w "$mp" ] || return 0

  n=$(read_targets_norm | sed 's#/.*##' | sort -u | grep -c .)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  fixes=$(read_fixes)
  case "$fixes" in ''|*[!0-9]*) fixes=0 ;; esac

  if acc_running; then running=1; else running=0; fi

  exp=$(cat "$PAUSE_FILE" 2>/dev/null)
  now=$(date +%s)
  case "$exp" in ''|*[!0-9]*) exp=0 ;; esac

  if [ "$exp" -gt "$now" ] && [ "$running" = "1" ]; then
    left=$(( (exp - now + 59) / 60 ))
    if [ "$n" -gt 0 ]; then
      desc="⏸ 已暂停｜还剩 $left 分钟｜守护 $n 个应用"
    else
      desc="⏸ 已暂停｜还剩 $left 分钟"
    fi
  elif [ "$running" = "1" ]; then
    if [ "$n" -gt 0 ]; then
      desc="● 运行中｜守护 $n 个应用｜已恢复 $fixes 次｜每 ${POLL_SLOW} 秒巡检"
    else
      desc="● 运行中｜还没选应用，打开 WebUI 配置"
    fi
  else
    if [ "$exp" -gt "$now" ]; then
      left=$(( (exp - now + 59) / 60 ))
      if [ "$n" -gt 0 ]; then
        desc="○ 未运行｜已暂停 $left 分钟｜守护 $n 个应用"
      else
        desc="○ 未运行｜已暂停 $left 分钟｜未配置应用"
      fi
    elif [ "$n" -gt 0 ]; then
      desc="○ 未运行｜守护 $n 个应用｜点检可尝试启动"
    else
      desc="○ 未运行｜未配置应用"
    fi
  fi

  cur=$(sed -n 's/^description=//p' "$mp" 2>/dev/null | head -n 1)
  [ "$cur" = "$desc" ] && return 0

  tmp="$mp.tmp.$$"
  {
    grep -v '^description=' "$mp" 2>/dev/null
    printf 'description=%s\n' "$desc"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$mp" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# ------------------------------------------------- 读 settings
# 唤醒一次 app_process 就把两个值都读回来（原来要两次，省一半唤醒开销）
AE=""
EAS=""
read_settings() {
  AE=""; EAS=""
  # 两个字段必须都可读取且格式有效。失败时绝不根据空值写回系统。
  dump=$(settings list secure 2>/dev/null) || dump=""
  ae_line=$(printf '%s\n' "$dump" | sed -n '/^accessibility_enabled=/{p;q;}')
  eas_line=$(printf '%s\n' "$dump" | sed -n '/^enabled_accessibility_services=/{p;q;}')
  if [ -n "$ae_line" ] && [ -n "$eas_line" ]; then
    AE=${ae_line#*=}; EAS=${eas_line#*=}
  else
    AE=$(settings get secure accessibility_enabled 2>/dev/null) || return 1
    EAS=$(settings get secure enabled_accessibility_services 2>/dev/null) || return 1
  fi
  case "$AE" in 0|1|null|NULL|Null) ;; *) return 1 ;; esac
  case "$EAS" in *Error*|*Exception*|*'\n'*) return 1 ;; esac
  # 空、null 均是合法空列表；非空条目必须是完整组件，避免丢弃无法解析的非目标。
  case "$EAS" in ''|null|NULL|Null) return 0 ;; esac
  printf '%s\n' "$EAS" | tr ':' '\n' | while IFS= read -r ent || [ -n "$ent" ]; do
    [ -n "$ent" ] || continue
    case "$ent" in *[!A-Za-z0-9_.$/]*) exit 1 ;; esac
    norm_one "$ent" >/dev/null || exit 1
  done
}

settings_put() { settings put secure "$1" "$2" 2>/dev/null; }

# ------------------------------------------------- 等系统就绪
wait_ready() {
  i=0
  while [ $i -lt 90 ]; do
    [ -e "$DATA_DIR/.stop" ] && return 1
    if read_settings; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  log "警告: 等待 settings 服务超时"
  return 1
}

# ------------------------------------------------- 核心：执行一轮检查
# 返回值 0 = 无事发生，1 = 做过修复
FIXED=0
apply_once() {
  FIXED=0
  if ! read_settings; then
    log "✗ 读取系统无障碍设置失败，未写入"
    return 1
  fi
  cur=$(norm_list "$EAS")
  tgt=$(read_targets_norm)
  tcnt=$(count_lines "$tgt")
  ocnt=0

  # 只跟踪选中的目标，绝不记录非目标应用的变化。
  selected_cur=""
  for t in $tgt; do
    if printf '%s\n' "$cur" | grep -qxF "$t"; then
      selected_cur="$selected_cur $t"
      ocnt=$((ocnt + 1))
    fi
  done
  if [ "$VERBOSE" = "1" ]; then
    log "· 巡检: 总开关=$AE 目标 ${tcnt} 个 / 在线 ${ocnt} 个 / 系统列表共 $(count_lines "$cur") 项"
  fi
  if [ -s "$STATE_FILE" ]; then
    removed=""
    for t in $tgt; do
      grep -qxF "$t" "$STATE_FILE" 2>/dev/null || continue
      printf '%s\n' "$cur" | grep -qxF "$t" || removed="$removed $t"
    done
    if [ -n "$removed" ]; then
      rcnt=$(printf '%s\n' $removed | grep -c .)
      rsample=$(printf '%s\n' $removed | head -n 3 | tr '\n' ' ')
      log "!! 守护的服务被移除 ${rcnt} 个: ${rsample}"
    fi
  fi
  if [ -n "$selected_cur" ]; then printf '%s\n' $selected_cur > "$STATE_FILE"; else : > "$STATE_FILE"; fi

  [ -z "$tgt" ] && return 0

  # ---- 找出缺失的目标 ----
  missing=""
  for t in $tgt; do
    printf '%s\n' "$cur" | grep -qxF "$t" || missing="$missing $t"
  done

  if [ -z "$missing" ] && [ "$AE" = "1" ]; then
    return 0
  fi

  # 原样保留非目标组件（包括简写与顺序）；即使旧配置 STRICT=1 也不能删除。
  case "$EAS" in ''|null|NULL|Null) new_val="" ;; *) new_val=$EAS ;; esac
  for t in $missing; do
    if [ -n "$new_val" ]; then new_val="$new_val:$t"; else new_val=$t; fi
  done
  [ -z "$new_val" ] && return 0

  mcnt=0
  _fix_t0=$(now_ms)
  if [ -n "$missing" ]; then
    mcnt=$(printf '%s\n' $missing | grep -c .)
    msample=$(printf '%s\n' $missing | head -n 3 | tr '\n' ' ')
    [ "$VERBOSE" = "1" ] && log "→ 恢复服务 ${mcnt} 个: ${msample}"
    [ "$VERBOSE" = "1" ] && log "· 写入前列表($(count_lines "$cur") 项): ${EAS:-(空)}"
  else
    [ "$VERBOSE" = "1" ] && log "→ 总开关 accessibility_enabled=1（当前 $AE）"
  fi

  if [ -n "$missing" ] && ! settings_put enabled_accessibility_services "$new_val"; then
    log "✗ 写入无障碍服务列表失败"
    return 1
  fi
  if [ "$AE" != "1" ] && ! settings_put accessibility_enabled 1; then
    log "✗ 写入无障碍总开关失败"
    return 1
  fi
  sleep "$VERIFY_SLEEP"
  # ---- 校验 ----
  sleep 1
  if ! read_settings; then
    log "✗ 无法验证无障碍设置"
    return 1
  fi
  cur2=$(norm_list "$EAS")
  bad=""
  for t in $tgt; do
    printf '%s\n' "$cur2" | grep -qxF "$t" || bad="$bad $t"
  done
  if [ -z "$bad" ] && [ "$AE" = "1" ]; then
    _fix_ms=$(( $(now_ms) - _fix_t0 ))
    if [ "$mcnt" -gt 0 ]; then
      log "✓ 已恢复 ${mcnt} 个（耗时 ${_fix_ms}ms，列表 $(count_lines "$cur2") 项）"
    else
      log "✓ 总开关已恢复（耗时 ${_fix_ms}ms）"
    fi
    [ "$VERBOSE" = "1" ] && log "· 写入后读回: AE=$AE 列表 $(count_lines "$cur2") 项"
    bump_fixes
    if [ -n "$tgt" ]; then printf '%s\n' $tgt > "$STATE_FILE" 2>/dev/null; else : > "$STATE_FILE"; fi
    FIXED=1
    rm -f "$DATA_DIR/.last_fail" 2>/dev/null
    # 写成功了：把目标从"系统拒绝"名单里摘掉（应用更新后可能又能用了）
    if [ -s "$REJECTED_FILE" ]; then
      _rt="$REJECTED_FILE.tmp.$$"
      : > "$_rt"
      while IFS= read -r _r || [ -n "$_r" ]; do
        [ -z "$_r" ] && continue
        printf '%s\n' "$tgt" | grep -qxF "$_r" || printf '%s\n' "$_r" >> "$_rt"
      done < "$REJECTED_FILE"
      mv -f "$_rt" "$REJECTED_FILE"
    fi
  else
    # 同一种失败 10 分钟内只记一次，免得日志被刷爆
    sig=$(printf '%s\n' $bad | sort -u | tr '\n' ',')
    nowt=$(date +%s)
    lf=""; lt=0
    if [ -f "$DATA_DIR/.last_fail" ]; then
      lf=$(sed -n '1p' "$DATA_DIR/.last_fail" 2>/dev/null)
      lt=$(sed -n '2p' "$DATA_DIR/.last_fail" 2>/dev/null)
    fi
    case "$lt" in ''|*[!0-9]*) lt=0 ;; esac
    if [ "$sig" != "$lf" ] || [ $((nowt - lt)) -gt 600 ]; then
      bcnt=$(printf '%s\n' $bad | grep -c .)
      bsample=$(printf '%s\n' $bad | head -n 2 | tr '\n' ' ')
      log "✗ 恢复失败 ${bcnt} 个（未生效）: ${bsample} —— 读回 AE=$AE / 列表 $(count_lines "$cur2") 项；组件可能已不存在，试 su -c acc_ctl clean"
      printf '%s\n%s\n' "$sig" "$nowt" > "$DATA_DIR/.last_fail" 2>/dev/null
      # 记进"系统拒绝"名单：以后不再尝试、界面标灰，免得每轮白写一次
      for _b in $bad; do
        grep -qxF "$_b" "$REJECTED_FILE" 2>/dev/null || printf '%s\n' "$_b" >> "$REJECTED_FILE"
      done
    fi

    # 自动检查绝不能删除、扩充或改写用户选择的 targets。
    return 1
  fi
  return 0
}

# Android sh 会关闭自行打开的额外 FD；busybox flock FILE PROG 执行同一个脚本。
# 所有单轮修复/后台巡检均通过 --locked-once 获取同一把内核文件锁。
if [ "$1" = "--desc" ]; then
  update_desc
  exit 0
fi
if [ "$1" = "--once" ]; then
  acc_lock_init || { log "✗ 无可用 flock，无法检查"; exit 1; }
  exec "$ACC_LOCK_TOOL" flock "$DATA_DIR/.work.lock" sh "$MODDIR/bin/acc_keeper.sh" --locked-once "$2"
fi
if [ "$1" = "--locked-once" ]; then
  if [ "$2" = "--fast" ]; then VERIFY_SLEEP=0.3; fi
  if acc_is_paused; then update_desc; exit 2; fi
  apply_once
  result=$?
  update_desc
  exit "$result"
fi

# 只有 busybox flock 包装器可进入 --daemon 模式；锁由内核在进程结束后释放。
if [ "$1" != "--daemon" ]; then
  acc_lock_init || { log "✗ 无可用 busybox flock，拒绝无锁启动"; exit 1; }
  exec "$ACC_LOCK_TOOL" flock -n "$DATA_DIR/.daemon.lock" sh "$MODDIR/bin/acc_keeper.sh" --daemon
fi
# flock 父进程持锁；关闭 daemon 自己持有的描述符，避免子命令继承。
acc_close_lock_fd "$DATA_DIR/.daemon.lock" || exit 1
# 此时已经持有常驻锁。旧标记只有在锁内才能清理。
rm -f "$DATA_DIR/.stop" 2>/dev/null
start_ts=$(date +%s)
TICKS=$(read_ticks)
EXIT_REASON="正常结束"
log "=== 守护启动 ${ACC_VERSION} (pid $$) ==="
acc_write_identity || { log "✗ 无法建立守护进程身份（cmdline 不匹配或 /proc 不可读）"; exit 1; }
chmod 600 "$PID_FILE" "$LOG_FILE" "$STATE_FILE" "$REJECTED_FILE" "$TARGETS_FILE" 2>/dev/null

# ---- 启动摘要：设备重启 / 进程重启、配置、目标，一次看全
log_startup() {
  _cur_boot=$(boot_id_now)
  _prev_boot=$(cat "$BOOT_STATE_FILE" 2>/dev/null)
  _up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  log "· 设备 $(getprop ro.product.model 2>/dev/null) / Android $(getprop ro.build.version.release 2>/dev/null) / 内核 $(uname -r 2>/dev/null)"
  log "· boot_id=${_cur_boot:-未知} 已开机 $(fmt_dur "${_up:-0}")"
  if [ -z "$_prev_boot" ]; then
    log "· 启动类型: 首次记录（没有上次 boot_id 可对比）"
  elif [ "$_cur_boot" = "$_prev_boot" ]; then
    log "· 启动类型: 进程重启（boot_id 未变 = 设备没有重启）"
  else
    log "· 启动类型: 设备重启（boot_id $(printf '%s' "$_prev_boot" | cut -c1-8) → $(printf '%s' "$_cur_boot" | cut -c1-8)）"
  fi
  [ -s "$LAST_EXIT_FILE" ] && log "· 上次退出: $(cat "$LAST_EXIT_FILE" 2>/dev/null)"
  log "· 配置 POLL_FAST=${POLL_FAST}s POLL_SLOW=${POLL_SLOW}s BOOT_FAST=${BOOT_FAST_SECONDS}s BOOST=${BOOST_TICKS} VERIFY=${VERIFY_SLEEP}s HEARTBEAT=${HEARTBEAT_SECONDS}s VERBOSE=${VERBOSE}"
  log "· 目标 $(read_targets_norm | grep -c .) 个: $(read_targets_norm | tr '\n' ' ')"
  printf '%s\n' "$_cur_boot" > "$BOOT_STATE_FILE" 2>/dev/null
}

acc_exit() {
  _now=$(date +%s)
  _dur=$((_now - start_ts))
  log "--- 守护退出 pid=$$ 原因=${EXIT_REASON} 运行=$(fmt_dur "$_dur") 累计检查=${TICKS} 修复=$(read_fixes)"
  printf 'pid=%s 时间=%s 运行=%s 检查=%s 修复=%s 原因=%s boot_id=%s\n' \
    "$$" "$(date '+%Y-%m-%d %H:%M:%S')" "$(fmt_dur "$_dur")" "${TICKS:-0}" "$(read_fixes)" "$EXIT_REASON" "$(boot_id_now)" \
    > "$LAST_EXIT_FILE" 2>/dev/null
  acc_cleanup_identity
  update_desc
}
trap 'acc_exit' EXIT
trap 'EXIT_REASON="收到 SIGTERM"; exit 0' TERM
trap 'EXIT_REASON="收到 SIGHUP"; exit 0' HUP
trap 'EXIT_REASON="收到 SIGINT"; exit 0' INT

log_startup

# 不做开机 adopt；用户未选中的服务永远不进入 targets。
wait_ready
update_desc
boost=0
PAUSE_LOGGED=0
_hb_next=$(( $(date +%s) + HEARTBEAT_SECONDS ))

nap() {
  _n=$1
  case "$_n" in ''|*[!0-9]*) _n=60 ;; esac
  [ "$_n" -lt 1 ] && _n=1
  # 单次 sleep：整段只用一个内核定时器。旧版把 60 秒切成 12 个 5 秒短睡眠，
  # 熄屏时系统会每 5 秒 suspend/resume 一次（冻结/解冻全部进程），
  # suspend-service 长期占 CPU，待机耗电明显变高。
  # 需要立刻停止/重启时，acc_ctl 校验进程身份后发 SIGTERM，trap 立即接管。
  if [ -e "$DATA_DIR/.stop" ]; then EXIT_REASON="检测到 .stop 标记"; exit 0; fi
  sleep "$_n"
  if [ -e "$DATA_DIR/.stop" ]; then EXIT_REASON="检测到 .stop 标记"; exit 0; fi
}

while :; do
  [ -e "$DATA_DIR/.stop" ] && { EXIT_REASON="检测到 .stop 标记"; break; }

  if acc_is_paused; then
    if [ "$PAUSE_LOGGED" = "0" ]; then
      _exp=$(cat "$PAUSE_FILE" 2>/dev/null)
      case "$_exp" in ''|*[!0-9]*) _exp=0 ;; esac
      _left=$(( (_exp - $(date +%s) + 59) / 60 ))
      [ "$_left" -lt 0 ] && _left=0
      log "⏸ 暂停中，停止巡检（还剩 ${_left} 分钟）"
      PAUSE_LOGGED=1
    fi
    update_desc
    nap "$POLL_SLOW"
    continue
  elif [ -f "$PAUSE_FILE" ]; then
    rm -f "$PAUSE_FILE" 2>/dev/null
    log "▶ 暂停结束，恢复巡检"
    PAUSE_LOGGED=0
  fi

  _fix_before=$(read_fixes)
  _tick_t0=$(now_ms)
  sh "$MODDIR/bin/acc_keeper.sh" --once >/dev/null 2>&1
  _tick_rc=$?
  _tick_ms=$(( $(now_ms) - _tick_t0 ))
  TICKS=$((TICKS + 1))
  printf '%s' "$TICKS" > "$TICKS_FILE" 2>/dev/null
  _fix_after=$(read_fixes)
  [ "$_fix_after" -gt "$_fix_before" ] && boost=$BOOST_TICKS

  case "$_tick_rc" in
    0) _tick_state="正常" ;;
    1) _tick_state="有错误" ;;
    2) _tick_state="已暂停" ;;
    *) _tick_state="返回码 $_tick_rc" ;;
  esac
  if [ "$VERBOSE" = "1" ]; then
    log "· 检查 #$TICKS 完成: ${_tick_state} 用时 ${_tick_ms}ms 目标 $(read_targets_norm | grep -c .) 个"
  elif [ "$_tick_ms" -ge "$SLOW_TICK_MS" ]; then
    log "! 检查 #$TICKS 偏慢: 用时 ${_tick_ms}ms 状态 ${_tick_state}"
  fi
  update_desc

  now=$(date +%s)
  iv=$POLL_SLOW
  if [ "$boost" -gt 0 ]; then
    boost=$((boost - 1)); iv=$POLL_FAST
  elif [ $((now - start_ts)) -lt "$BOOT_FAST_SECONDS" ]; then
    iv=$POLL_FAST
  fi

  if [ "${HEARTBEAT_SECONDS:-0}" -gt 0 ] && [ "$now" -ge "$_hb_next" ]; then
    log "♥ 心跳: 运行 $(fmt_dur $((now - start_ts))) 检查 #$TICKS 修复 $(read_fixes) 目标 $(read_targets_norm | grep -c .) 个 间隔 ${iv}s"
    _hb_next=$((now + HEARTBEAT_SECONDS))
  fi

  nap "$iv"
done
exit 0
