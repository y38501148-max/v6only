# v6only — 校园网双栈网络配置工具

本项目保留 `v6only` 名称。**当前 macOS 模式允许普通 IPv4 和 IPv6 联网，不能保证双栈网站、代理或所有应用都使用 IPv6。** 使用 IPv6 DNS 上游也不等于只返回 AAAA 记录。地址选择由操作系统、应用、DNS 结果和链路状况共同决定，参见 [RFC 8305](https://www.rfc-editor.org/rfc/rfc8305.html)。

本项目用于网络兼容性诊断和配置研究。请遵守所在网络的使用政策；IPv6 可达性不能证明流量是否计费。

## 平台范围

| 平台 | 当前行为与验证范围 |
|---|---|
| macOS | 本次修复和验收的主要平台；Bash 3.2、系统 PF、networksetup、launchd；有模拟系统命令的回归测试 |
| Windows | 独立 PowerShell 实现；CI 检查部分系统 API，不等于完整实机验收；仅阻断脚本中列出的 IPv4 DNS 地址 |
| Android | 实验性旧实现，行为与桌面端不同；构建成功不代表 VPN 转发正常，不建议作为稳定版部署 |

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

旧版本没有保存完整的安装前 DNS，因此迁移后的回滚基线是**迁移时的实际设置**。备份不能补回旧版已经丢失的历史配置。新版本正常开启/关闭不重新加载 PF 主规则、不全局关闭 PF、不清除其他组件的状态表。

### 验证结果应如何解读

`test-suite.sh` 分别检查 IPv4、IPv6 和校园网关的连通性，并输出实际远端地址。网站返回 HTTP 错误也可能说明网络已连接；业务登录是否正常需要另行验证。代理存在时，浏览器最终使用哪个出口需要检查代理连接，不能从本地 `127.0.0.1:7890` 推断。

测试不会注销校园账号、清理系统缓存或修改代理开关。PF 读回需要 root；普通用户运行会明确跳过这一项。

## Windows 与 Android

Windows 入口为 `windows/v6only.ps1`，保留 `-On/-Off/-Watch/-Test/-Install/-Uninstall` 接口。该版本不属于本次 macOS 实机验收范围。

Android 入口为 `android/build-apk.sh`。旧 VPN 数据泵尚未实现可靠的用户态 IP 转发；不要把把数据包写回 TUN 当作系统自动 NAT。当前仅保留源码和构建检查，不宣称与 macOS 功能等价或已实机验收。

## CI

`.github/workflows/ci.yml` 包含 macOS ShellCheck、Bash 3.2 回归测试、PF 只解析检查，以及现有 Windows API 冒烟与 Android 构建任务。回归测试在临时目录模拟系统命令，覆盖幂等检查、失败回滚、用户设置保留、校园识别、暂停与重入，不操作 runner 的真实网络。
