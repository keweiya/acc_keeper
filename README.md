# 无障碍守护 (acc_keeper)

KernelSU / KernelSU Next / Magisk 模块。开机自动启用指定应用的无障碍服务，并在它被系统、安全中心、省电策略或任何后台清理关掉后自动恢复，同时记录每一次"被关闭"的时间与组件。带 WebUI。

## 原理

无障碍服务的启用状态本质只是 `Settings.Secure` 里的两个值：

```
enabled_accessibility_services = 包名/类名:包名/类名
accessibility_enabled = 1
```

`AccessibilityManagerService` 监听这两个值的变化——写进去就**立即生效**，不需要重启、不需要点授权弹窗。从「设置 → 无障碍」手动点开，做的也只是这两次写入。

模块做的事：

1. `service.sh` 在开机 `late_start service` 阶段拉起守护进程；
2. 守护进程周期性读取这两个值，发现目标组件缺失或总开关被关就补回去；
3. 每次检测到服务消失/新增都写日志——这就是"监控"部分。

## WebUI

KernelSU 管理器 → 模块卡片 → **打开**。

**顶部只有状态，没有统计**：

```
无障碍守护                              ⋯
● 运行中 · 守护 2 个应用 · 每 60 秒巡检
```

圆点绿=运行中、橙=已暂停、灰=未运行；后面那句跟着状态变（暂停时显示"还剩 N 分钟"）。

**下面就是搜索 + 应用列表**（没有多余的汇总卡）：

- 应用图标 + 系统里的中文名（KernelSU 的 `ksu://icon/<包名>` 与 `ksu.getPackagesInfo()`）
- 只显示**手机上下载安装的应用**（`isSystem=false`），设置、TalkBack、系统界面这类系统应用不进来
- 应用名是异步补上的：KernelSU 管理器要等 WebUI 打开后才去抓应用列表，所以列表会先出包名、1~3 秒后自动换成中文名（重试 5 次）
- 已守护的排最上面，第三行是状态：守护中·服务运行中（蓝）/ 守护中·等待恢复（橙）/ 已声明未开启
- 不做静态过滤：能不能启用由系统实际行为决定。第一次写进去被系统丢弃的组件，会记到 `/data/adb/acc_keeper/rejected.txt`，界面标"系统不接受此服务（已记录）"、开关置灰、不再重试；应用更新后重新打开成功的话，记录会自动清掉
- 开关 = 立即开启或关闭该应用的无障碍服务（关掉会同时取消守护，不然会被弹回来）

**⋯ 打开「设置与操作」底部面板**（iOS 分组列表样式）：

| 分组 | 内容 |
|---|---|
| 显示 | 仅看已守护 / 显示全部应用（iOS 小开关） |
| 巡检 | 轮询间隔 →（显示当前值，点进去改） |
| 操作 | 暂停守护 30 分钟（暂停后变成"恢复守护"）/ 查看日志 |
| 外观 | 跟随系统 / 浅色 / 深色（分段控件，记在 localStorage） |
| — | 关于（版本号 + 当前状态） |

**只有两个刷新入口，不重复**：

- 下拉刷新 → 重新读一遍数据（`acc_ctl dump`）
- 右下角「立即检查」→ 真跑一次检查修复（`acc_ctl apply`）再刷新

没有第三个"刷新"按钮。默认只显示"有服务的用户应用 + 已守护的应用"。

- 系统里**已经开启**的无障碍服务，打开页面时自动纳入守护（开关直接是开的）
- 面板打开时背后列表锁死，点遮罩空白处即可关闭

## 模块卡片上的状态

`module.prop` 里的 `description` 会被守护进程实时改写，所以 KernelSU 模块卡片上看到的就是当前状态，不是一句宣传语：

| 状态 | 显示 |
|---|---|
| 正常 | `● 运行中｜守护 2 个应用｜已恢复 7 次｜每 60 秒巡检` |
| 暂停 | `⏸ 已暂停｜还剩 27 分钟｜守护 2 个应用` |
| 进程没起来 | `○ 未运行｜守护 2 个应用｜重启设备可恢复` |
| 还没选应用 | `● 运行中｜还没选应用，打开 WebUI 配置` |
| 刚装上没重启 | `○ 尚未启动｜安装后重启生效｜在 WebUI 里选择要守护的应用` |

每轮巡检、开关任一应用、暂停/恢复、改间隔都会刷新它。管理器里的模块列表要重新进一次才会重新读取。

## 命令行

```sh
su -c acc_ctl                          # 状态总览
su -c acc_ctl scan                     # 列出设备上所有无障碍服务
su -c acc_ctl on com.example.app       # 开启 + 守护
su -c acc_ctl off com.example.app      # 关闭 + 取消守护
su -c acc_ctl add com.example.app      # 只加守护（多个服务时用 acc_ctl add 包名/类名）
su -c acc_ctl del com.example.app      # 只取消守护
su -c acc_ctl status                   # 系统值 / 进程 / 最近日志
su -c acc_ctl log 50
su -c acc_ctl apply                    # 立即检查修复一次
su -c acc_ctl pause 30                 # 暂停守护 30 分钟
su -c acc_ctl resume
su -c acc_ctl interval 5 60            # 改轮询间隔：快速 5 秒 / 稳定 60 秒（会重启守护进程）
su -c acc_ctl restart                  # 改完 settings.conf 后让它生效
su -c acc_ctl clean                   # 清掉守护列表里本机已不存在的组件
```

`acc_ctl` 已挂到 `/system/bin/acc_ctl`。overlay 没生效时用完整路径：
`sh /data/adb/modules/acc_keeper/bin/acc_ctl status`

## 它到底会不会自动开回来

会。在系统设置里关掉目标应用的无障碍之后：

1. 守护进程下一次醒来（默认 **60 秒**内，平均 30 秒）读到 `enabled_accessibility_services` 少了这个组件，或者 `accessibility_enabled` 变成 0；
2. 把组件合并写回列表、把总开关写回 1；
3. 日志里留下三行：`!! 检测到无障碍服务被移除` → `→ 恢复服务` → `✓ 恢复成功`。

例外只有三种：开了 `acc_ctl pause`、守护进程没起来（`acc_ctl status` 可以看到）、或者目标组件名写错（日志里是 `✗ 恢复失败`）。另外注意：系统的无障碍设置页面不会实时刷新，你关掉后停在那个页面看到的是旧状态，退出去再进就是"开"了。

## 耗电

守护进程就是一个跑 `sleep` 的 shell 循环，**不持有 wakelock**，不会阻止系统休眠；每次检查才会唤起一次 `app_process`（`settings` 命令）读值。

| 场景 | 唤醒次数 | 量级 |
|---|---|---|
| 开机后前 3 分钟（3 秒一次） | ≈60 | 一次性 |
| 稳定期（60 秒一次） | 1440/天 | 每次约 100~300ms CPU |
| 修复成功后（3 秒一次，10 次） | 突发 10 次 | 防止安全中心连续补刀 |

按 60 秒算，一天大约 3~8 分钟 CPU 时间，折算待机耗电在 0.1% 量级——比微信一个心跳还轻。想改间隔：WebUI「更多 → 轮询间隔」，或者 `acc_ctl interval 5 30`，两种方式都会立即重启守护进程生效；也可以直接改 `settings.conf` 里的 `POLL_FAST` / `POLL_SLOW` 再 `acc_ctl restart`。

## 日志

`/data/adb/acc_keeper/acc_keeper.log`：上限 **1MB**，超过就滚动覆盖（只保留最新的一半），不会无限长大。

**默认只记事件和错误**，启动、新增、每次恢复的明细都不写（`VERBOSE=1` 才写）：

```
[2026-11-21 00:48:22] !! 检测到无障碍服务被移除 1 个: com.omarea.vtools/…AccessibilitySceneMode
[2026-11-21 00:48:24] ✓ 已恢复 1 个
```

一次被关 → 一次恢复，正好两行。失败长这样：

```
✗ 恢复失败 1 个（未生效）: x/y —— 组件可能已不存在，试 su -c acc_ctl clean
```

同类失败 10 分钟内只记一次，不会刷屏。

恢复失败时守护进程会自动做一次校验：拿 `acc_ctl scan-list` 对比守护列表，把**本机已经不存在的组件**从 `targets.txt` 里摘掉，避免"每轮都写、永远失败"的死循环。

要排查问题就把 `/data/adb/acc_keeper/settings.conf` 里的 `VERBOSE` 改成 1 再 `acc_ctl restart`，会额外记录进程启动、新启用、每轮恢复的完整明细。

## 配置文件

- `/data/adb/acc_keeper/targets.txt` — 守护列表，一行一个组件，支持 `#` 注释
- `/data/adb/acc_keeper/settings.conf` — `POLL_FAST` / `POLL_SLOW` / `BOOT_FAST_SECONDS` / `BOOST_TICKS` / `STRICT`
- `/data/adb/acc_keeper/acc_keeper.log` — 变更日志（超过 256KB 自动截半）

`STRICT=1` 会把系统里的无障碍服务强制改成"只保留列表中的"（移除其它应用的），一般不要开。

## 排查

**WebUI 一直转圈 / 列表空白**

v1.5.0 有个致命 bug：调用 `ksu.exec` 时把回调函数当成了第二个参数，而 KernelSU 的签名是 `exec(cmd, optionsJson, callbackFuncName)` —— 第三个参数必须是**注册在 window 上的函数名字符串**。传错的结果是原生侧永远不回调，页面等 20 秒超时。v1.5.1 已修，界面现在会明确写出"命令超时"或"读取失败"，不再是空白。

分两层排查：

```sh
su -c acc_ctl dump | head -20     # 有输出 = 模块本身正常，问题在 WebUI 桥接
su -c acc_ctl status              # 守护进程是否在跑、系统里的值是什么
```

- `dump` 有 `H|` `T|` `S|` `P|` 行 → 模块正常。WebUI 还空着，就把这条命令的完整输出发我。
- `dump` 报错/无输出 → 模块侧问题，看 `acc_ctl status` 和 `/data/adb/acc_keeper/acc_keeper.log`。

**扫描不到任何无障碍服务**（列表只剩"没有可显示的应用"）

不同 ROM 的 `cmd package query-services` 输出格式不一样：有的给 `name=com.foo/.Svc`，有的把 `name=` 和 `packageName=` 分成两行。v1.5.1 改成三个来源合并（带斜杠的、分开的、`dumpsys accessibility`），覆盖这两种。

## 注意

- **它会和你的手动操作对抗**：在系统设置里关掉目标服务，60 秒内会被重新打开。要临时关闭：`acc_ctl pause 30`。
- 只能恢复"设置里的开关状态"。应用本身崩溃、被冻结、被卸载时无能为力（日志里能看到是哪个组件没恢复）。
- 如果目标组件名写错，日志会出现 `✗ 恢复失败`。
- 模块脚本以 root 运行，`settings put secure` 对 uid 0 是放行的，不需要额外授权。
- WebUI 的图标和中文名来自 KernelSU 管理器的 WebView 接口（`ksu://icon/<包名>`、`ksu.getPackagesInfo()`）；如果你的 KernelSU 版本不提供这些，会自动退回"包名 + 首字母色块"，功能不受影响。
