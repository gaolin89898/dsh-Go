# gaolin89898 Remote 集成验证

日期：2026-11-10。

- 目标仓库：`https://github.com/gaolin89898/ds-harness-remote.git`。
- 固定验证版本：`4f68634bd8adf4e83723732382e74e4a733197af`，Host 插件 0.6.4。
- 默认 Server：`https://remote.gaolin.ink`；默认控制台：`https://remote.gaolin.ink/app`。
- App 继续使用 `packages/dsh_remote` 的 Dart 实现，不将 TypeScript Host 插件或 Server 打入 APK。原始 MIT 署名与历史协议来源保留。

## 真实 Server / Host

Windows 上从固定提交导出干净源码，构建实际 `apps/server`，使用独立的临时数据目录、回环地址与临时账号。通过 DSH 0.2.2-rc.1 的插件管理器将同一提交的 Host 插件装入独立 `DSH_HOME`，不使用日常 Host 或线上账号。Host 凭据放在该 fork 的 `ds-harness-remote/servers/<scope>/host` 路径。

`dart test -t live test/live_remote_test.dart -r expanded`：4 项全部通过。

1. Relay、Noise 握手、Typert carrier 与主机身份固定。
2. 对话列表、创建、重命名、归档、实时事件、模型及权限、临时测试 Key 的设置与清除、工作区和分块传输。
3. 不支持的上传在客户端显式拒绝。
4. 令牌刷新后断线重连、订阅重新同步。

验证过程不发送模型提示；临时 Host 和 Server 已停止，临时凭据与服务状态已删除。`run_e2e.sh` 默认获取此 fork 的固定提交，Host 插件也取自同一 Git 提交；可通过 `UPSTREAM` / `PLUGIN_SPEC` 指向本地源码和打包产物。

## 检查与边界

- `dart analyze`（`packages/dsh_remote`）：通过。
- `dart analyze`（整个 `app`）：通过。使用独立 Flutter 3.47.9 / Dart 3.13.7；未改系统 SDK 或依赖锁文件。
- App 定向测试：132 项通过，覆盖默认服务器的新登录与已有配置、重新登录、项目链接、账号存储隔离、扫码配对、登录取消与并发、退出归属和启动恢复。
- 在 WSL Ubuntu 26.04 上使用与 CI 相同的 Flutter 3.47.7 / Dart 3.13.5、Noto CJK `1:20230817+repack1-3` 与 Noto Color Emoji `v2.051`，重新生成受影响的 12 张深浅色 golden；随后运行 `flutter test --no-pub test/remote/remote_golden_test.dart`，全部 26 项通过，包括未更新的 SSH 与抽屉基准。新默认未登录页截图已检查，文字和控件无重叠。CI 的系统版本为 Ubuntu 24.04；本次未改 CI、系统 SDK 或依赖锁文件。
- 包全量测试：497 通过、4 个未配置的 live 测试跳过、2 项失败。失败属于 `activation uses fresh descriptor` 用例关闭连接时，Fake Host 向已关闭 WebSocket 发送 stream-close 的竞态；在未修改的 `1c5b2200` 源码上定向运行同组测试也复现了 `Bad state: StreamSink is closed`。本次没有改动该 fixture 或相关生产逻辑。
- 默认服务公开只读检查：`/health` 与 `/app` 返回 200；OAuth provider 接口返回 404，因此默认登录入口使用邮箱和密码。
- 上述阶段没有使用线上账号登录、构建 APK、进行 Android 真机或公网 WebRTC/TURN 验收，仅验证 Windows 回环 Relay 链路。后续 APK 与真机结果见下文。

## 原生手机 Host 设置

入口为 `设置 › 本机引擎 › 允许远程连接此手机`，首次开启使用原生表单填写服务器、设备名、邮箱和密码。通过本机已认证的 HTTP 连接安装固定提交的 fork，写入本机插件配置、重载插件并登录 Host。密码不写入 App 状态或磁盘；插件自行保管其授权凭据。关闭会停用整个 Remote bundle，保留安装、对话和工作区。

实现固定绑定 `localConnectionProvider`。安全模式、引擎停止、正在重连或连接错误时不能操作；当前正在使用的远程主机不参与配置。状态来自实际插件响应；停用失败或需要重启时不会冒充已关闭，重启提示保留到引擎换代。

### 真实原生后端联调

在 WSL Ubuntu 26.04 使用 Node 24.22.1、DSH 0.2.2-rc.1 的仓库锁文件和全部固定补丁，加载仓库的真实配置桥及固定 fork Server。独立临时 `DSH_HOME`、回环地址和合成账号，不使用线上账号，也不发送模型提示。

`flutter test --no-pub test/engine/phone_remote_host_live_test.dart`：1 项通过，执行以下完整流程：

1. 从未安装状态，通过原生 controller 调用插件管理器安装固定 Git 提交。
2. 配置 Host、登录、确认授权和在线状态。
3. 用另一 `RemoteAccount` 登录并发现主机，核对设备名称。
4. 本机创建对话，远端读取并改名，本机确认同一对话的变化。
5. 更新设备名称、重载插件，再停用并确认实际关闭且保留安装。

真实接口发现并覆盖了两个差异：`settings.get` 省略设备名，需要从本机配置桥读取；控制路由移除后 DSH 对 POST 返回 405，也属于停用后的不可用响应。GitHub 连接曾触发引擎默认 5 秒检查超时；成功联调使用临时插件管理器配置将连接超时放宽到 30 秒，未更改仓库运行时默认值。

此 live 测试默认跳过；运行时需为一次性引擎与 Server 设置 `DSH_PHONE_HOST_LIVE_URL`、`DSH_PHONE_HOST_LIVE_TOKEN`、`DSH_PHONE_HOST_LIVE_SERVER`、`DSH_PHONE_HOST_LIVE_EMAIL` 和 `DSH_PHONE_HOST_LIVE_PASSWORD`。测试结束已停止服务，清理合成授权与设备私钥。

### 界面与回归

- App 静态分析通过；l10n、指南生成检查通过。
- 新增 controller、HTTP 契约及 widget 测试覆盖开启、取消、登录失败、关闭失败、重启提示、引擎换代、并发操作、控制路由启动延迟和本机连接边界。
- 320×640 中英文、深浅色表单的 4 张 golden 通过；键盘弹出后启用按钮可滚动到。引擎页深浅色及未安装环境的中英文 5 项既有 golden 通过。
- 引擎测试全部通过。完整引擎与 Remote 回归曾发现 1 项受页面布局影响的等待时机问题，已修正并通过引擎回归；另外 3 项 SSH 测试失败在干净的 `1c5b2200` 上同样复现：`ssh_link_test` 的关闭端口断言，以及 `remote_bootstrap_test` 的两项遗留进程断言。本次未改这些 SSH 生产代码或断言。
- 此阶段 Android 真机验收未完成：检查时现有安装不可调试且本地缺少匹配签名；当时 `adb devices -l` 无连接设备。此阶段未覆盖安装、卸载、清除手机数据、构建或发布 APK。Linux 回环验证不能代替 Android/PRoot 和公网网络验收。

### APK 与 Android 真机联调

本地构建 `dist/dsh-go-1.0.14-11101414-arm64-local.apk`，版本 `1.0.14+11101414`，使用本机 Android Debug key 签名的 release 包，未发布。APK 的 v2 签名、ARM64 运行时与嵌入文件摘要校验通过；构建信息和 SHA256 位于同目录。用户自行安装后，通过 USB 在一加 9RT（MT2110）、Android 16、ARM64 上联调，未卸载或清除应用数据。

实际通过的操作：

1. 原生设置完成 Host 配置与授权，连接默认 Server；手机显示在线，控制台确认设备为在线 Host。
2. 已登录相同账号的 Windows DSH 0.2.2-rc.1 发现并连接手机，核对 Harness 和 Remote 插件版本。
3. 电脑读取手机的 `/root` 目录，登记并选择 `/root/workspace`。手机原生工作区选择器能看到同一个工作区。
4. 手机引擎日志记录成功的远程 transport describe、stream open 和 stream close 请求。

未通过和待核实项：

- 电脑打开手机工作区时两次触发 `web boot` 错误，涉及 `@deepseek-ai/dsh-experimental-client-ui-cot-translation`，第二次还包含 `@astervolans/dsh-opencode-go-usage` 的 import failed。没有禁用桌面插件或修改桌面配置，尚未定位根因。
- 手机切到后台再返回后，原生 Host 设置曾显示操作失败；当时电脑仍可连接并读取目录。重新进入本机引擎页后恢复在线，再次切到后台并返回仍显示在线。尚未定位此前状态读取异常的原因，不能据此判定 Host 掉线。
- 手机没有已有会话；本次未发送模型提示，未验证真机上的会话创建、读取、重命名或双端实时同步。上述 Linux 合成环境中的会话测试不能替代此项。
- 尚未单独验证公网 WebRTC/TURN、长时间后台存活或省电策略下的连接恢复。

联调结束保留手机 Host 开启和已登记工作区，电脑恢复本机界面。构建时的 `androidDeviceTested: false` 是构建时快照，不作为本次真机验收结论；本次结果为连接与工作区验证部分通过，会话操作验收未完成。
