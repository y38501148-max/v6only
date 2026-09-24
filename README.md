# v6only — 校园网双栈网络配置工具

本项目保留 `v6only` 名称。**各平台只在识别到校园网时应用设置；手动入口也不能绕过这一条件。离开校园网后撤销本工具配置，普通网络使用原有设置。**

**当前 macOS 模式允许普通 IPv4 和 IPv6 联网，不能保证双栈网站、代理或所有应用都使用 IPv6。** 使用 IPv6 DNS 上游也不等于只返回 AAAA 记录。地址选择由操作系统、应用、DNS 结果和链路状况共同决定，参见 [RFC 8305](https://www.rfc-editor.org/rfc/rfc8305.html)。

本项目用于网络兼容性诊断和配置研究。请遵守所在网络的使用政策；IPv6 可达性不能证明流量是否计费。

## 平台范围

| 平台 | 当前行为与验证范围 |
|---|---|
| macOS | 本次修复和验收的主要平台；Bash 3.2、系统 PF、networksetup、launchd；有模拟系统命令的回归测试 |
| Windows | 独立 PowerShell 实现；CI 检查部分系统 API，不等于完整实机验收；仅阻断脚本中列出的 IPv4 DNS 地址 |
| Android | 已合并联网与后台恢复修复；宿主回归及模拟器记录见 `android/TESTING.md`，真实校园/iQOO 环境仍需实机验收 |

## macOS 做了什么

- Wi-Fi 的 DNS 设置为 `202.112.128.50`、`202.112.128.51`、`2400:3200::1`。校园 DNS 同时返回 A 和 AAAA，放在首选位置能保留内部域名解析并减少公共 IPv6 DNS 超时的影响；公共 IPv6 DNS 作为备用。配置与状态检查使用同一个来源。
- 为 `gw.buaa.edu.cn` 设置专用校园 DNS resolver，避免公共 DNS 缺少校园内部记录；为该域名添加代理直连例外，保留其余代理设置。
- 仅在独立 PF anchor `com.apple/v6only` 中过滤外部 IPv4 的 TCP/UDP 53 端口；放行 `10/8` 和 `202.112.128/24` 内的 DNS。它不拦截 DoH、DoT，也不控制代理的出口协议。
- 守护每 20 秒只读检查配置；配置未变化时不再加载规则、修改 DNS、清缓存或反复联网自检。失败后至少等待 300 秒再重试。
- 校园识别使用精确的校园 DNS、域名后缀或 SSID；普通 `10/8` 网关不再被直接判定为校园网。
- 开启前保存原 DNS、网关 resolver 和代理例外的状态；关闭时撤销自身改动，保留后续用户修改和其他 PF 规则。

## macOS 安装与使用

```bash
# 在仓库根目录运行：
python3 -m unittest discover -s tests -v  # 不需要 root，不修改本机网络
shellcheck -S warning macos/*.sh
sudo ./macos/install-launchd.sh
sudo /usr/local/lib/v6only/test-suite.sh
```

安装器会先检查文件与语法、建立备份，再部署守护程序。所有被引用的脚本都包含在 `macos/` 中。

PF 的主规则必须有系统标准入口 `anchor "com.apple/*"`。安装器不会未经检查覆盖主规则：

- **旧版迁移**：如果安装提示缺少入口，且本机运行本项目旧版的三条主规则，使用 `sudo ./macos/install-launchd.sh --migrate-legacy`。它仅接受精确匹配的旧规则，备份原安装后恢复 `/etc/pf.conf` 中的系统规则，再加载独立 anchor。其他自定义主规则会导致迁移停止。
- **空规则初装**：确认没有现存 PF 过滤和 NAT 规则时，可用 `sudo ./macos/install-launchd.sh --initialize-pf` 初始化系统入口。
- **其他自定义 PF 配置**：由管理员把独立 anchor 接入现有规则，再安装；不要直接清空主规则。

```bash
sudo /usr/local/lib/v6only/v6on.sh               # 手动开启；重复执行不重复写入
sudo /usr/local/lib/v6only/v6ctl.sh status       # 只读核对实际设置
sudo /usr/local/lib/v6only/v6off.sh              # 回滚并暂停自动配置 30 分钟
sudo /usr/local/lib/v6only/test-suite.sh         # 只读设置检查和少量联网请求
sudo /usr/local/lib/v6only/test-suite.sh --offline  # 只读，不发联网探测请求
sudo /usr/local/lib/v6only/uninstall.sh          # 卸载并恢复本工具管理的设置
```

`v6on.sh` 可以解除手动暂停。离开校园网时的自动回滚不设置暂停，不影响稍后回到校园网。暂停保存为到期时间，不再启动后台 `sleep` 清除标记。

安装器默认配置 `Wi-Fi/en0`。其他服务可先手动测试，例如 `sudo env SERVICE='USB 10/100 LAN' IFACE=en3 ./macos/v6on.sh`；不要在不同服务间切换而不先关闭原配置。

### 状态与恢复

| 路径 | 内容 |
|---|---|
| `/usr/local/lib/v6only/` | 安装的程序 |
| `/Library/LaunchDaemons/edu.buaa.v6only-watch.plist` | 开机守护 |
| `/var/db/v6only/original/` | 当前开启前的配置快照 |
| `/var/db/v6only/backups/install.*` | 每次安装前的版本、规则和设置备份；不会自动删除 |
| `/var/run/v6only.active` | 已应用标记，状态检查还会核对实际 DNS/PF/resolver |
| `/var/run/v6only.suspend` | 手动暂停到期时间；空文件代表持续暂停 |
| `/var/log/v6only.log` | 状态变化与失败记录 |

旧版本没有保存完整的安装前 DNS。迁移时若 DNS 精确匹配旧版本写入的三个地址，关闭后的基线恢复为 DHCP，避免把旧校园配置带到普通网络；迁移时的原始清单仍在安装备份中。其他自定义 DNS 会原样保存。新版本正常开启/关闭不重新加载 PF 主规则、不全局关闭 PF、不清除其他组件的状态表。

### 验证结果应如何解读

`test-suite.sh` 分别检查 IPv4、IPv6 和校园网关的连通性，并输出实际远端地址。网站返回 HTTP 错误也可能说明网络已连接；业务登录是否正常需要另行验证。代理存在时，浏览器最终使用哪个出口需要检查代理连接，不能从本地 `127.0.0.1:7890` 推断。

测试不会注销校园账号、清理系统缓存或修改代理开关。PF 读回需要 root；普通用户运行会明确跳过这一项。

## Windows

Windows 入口为 `windows/v6only.ps1`，提供 `-On/-Off/-Watch/-Test/-Install/-Uninstall` 接口。

## Android 使用

1. 安装 `v6only.apk`（本地构建：`cd android && ./build-apk.sh`），打开应用并点击「启动服务」授予 VPN 权限。
2. 默认自动模式：校园 DNS（`202.112.128.50/51`）、`buaa.edu.cn` 搜索域或 BUAA Wi-Fi 名称匹配时连接；离开校园网后断开 VPN，**前台服务继续监听**。普通 `10.x` 私网、蜂窝网络、VPN 自身不再作为校园网证据。
3. 若网络未提供校园 DNS／域名，可通过「授权校园 Wi-Fi 名称识别」授予精确位置权限并打开系统定位；后台识别新接入的 Wi-Fi 还需在系统位置权限中选择「始终允许」。应用只读取 Wi-Fi 名称，不读取坐标。SSID 不可读取时，界面会显示未识别到；可关闭自动模式使用手动连接。
4. 手动模式也仅允许在校园网连接，离开校园网后停止服务，回校需再次手动启动；点击「停止服务」同时停止 VPN 和自动监听，不会因网络变化自行重启。下次启动恢复保存的模式。
5. 划掉最近任务不停止前台服务。已启用的服务会在系统回收后尝试恢复，并在重启／应用更新后恢复；从未启用或明确停止的服务不会自动开启。
6. **iQOO／vivo**：在系统设置中允许应用自启动和后台运行（部分版本称为「后台高耗电」），将电池策略改为不限制，并在最近任务中锁定应用。应用内提供电池和应用设置入口。厂商强制清理、系统「强行停止」无法由应用保证恢复；强行停止后需手动打开应用。

Android 1.0.1 修复说明：

- 移除 `0.0.0.0/0` 全量捕获、丢弃 IPv4、TUN 原样回写和没有转发器的虚假 DNS。
- 使用当前物理网络下发的真实 DNS，优先列出有路由的 IPv6 DNS，保留 IPv4 DNS；不篡改 A／AAAA 回答，保留校内域名解析。
- 显式 `allowFamily(AF_INET)` 与 `allowFamily(AF_INET6)`；不添加默认路由，DNS、TCP、UDP、IPv4 和 IPv6 由 Android 原生网络栈处理。仅不添加 IPv6 路由并不会自动放行 IPv6。
- 这不是加密隧道或全流量防火墙，也不强制浏览器使用 IPv6。网站最终走 IPv4 还是 IPv6 取决于可达性、系统与浏览器的地址选择；浏览器自带 DoH／系统私人 DNS 保持其各自行为。
- 自动模式由前台服务持有网络回调，支持断网等待、链路属性变化和恢复；VPN 成功建立后才显示已连接，停止时实际关闭文件描述符。
- 此分流模式不支持「阻止未通过 VPN 的连接」；已声明不支持系统始终开启 VPN，避免该选项导致直连流量被阻断。

构建默认使用本地调试证书。**调试包不能覆盖不同证书签名的旧 Release**，需使用原发布密钥重新签名，或卸载旧包后安装（会清除旧设置）。正式签名可设置 `V6ONLY_KEYSTORE`、`V6ONLY_KEY_ALIAS`、`V6ONLY_STORE_PASSWORD`、`V6ONLY_KEY_PASSWORD` 环境变量后运行构建脚本；不要提交密钥或密码。SDK 通过 `ANDROID_HOME` 定位，也可覆盖 `ANDROID_BUILD_TOOLS` 和 `ANDROID_PLATFORM_JAR`。


## CI

`.github/workflows/ci.yml` 包含 macOS ShellCheck、Bash 3.2 回归测试、PF 只解析检查，以及现有 Windows API 冒烟与 Android 构建任务。回归测试在临时目录模拟系统命令，覆盖幂等检查、失败回滚、用户设置保留、校园识别、暂停与重入，不操作 runner 的真实网络。
