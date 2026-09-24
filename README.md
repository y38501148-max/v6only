# v6only — 校园网 IPv6 优先工具（macOS / Windows / Android）

> 源自北航 Srun/深澜计费系统计费旁路漏洞的验证性配置工具（见《校园网计费漏洞复现报告》）。
> 计费会话仅绑定 IPv4（`online_ip6: "::"`），IPv6 流量游离于计量管道之外；
> v2 方案按「**双栈站走 v6，v4-only 站直连 v4**」的语义实现，不再一刀切封 v4。

> ⚠️ **合规声明**：本工具是计费模型缺陷的验证性产物，仅用于安全研究与漏洞验证。
> 请勿用于实际规避资费。发现此类漏洞请向学校网络中心负责任披露。

## 工作原理（v2）

```
任意请求
  ├─ DNS：v6 上游优先（AliDNS/CNGI）+ 校园 v4 DNS 兜底
  │        → 双栈域名稳拿 AAAA；v4-only 域名走兜底拿 A
  ├─ 连接：系统地址选择（RFC 6724 / Happy Eyeballs）偏好 v6
  │        → 双栈站实际走 v6（v6 RTT 通常远低于 v4，竞速必胜）
  │        → v4-only 站自然直连 v4，无感知
  └─ 防绕过：封外部 v4 明文 DNS（8.8.8.8 等硬编码），校园 DNS 放行
```

**为什么不全局封 v4（v1 行为）**：实测发现 kedaya.ai 等 v4-only 站点会彻底断网，
而 Happy Eyeballs 竞速下 v6 占优时双栈站根本不需要封 v4 也会走 v6 —— v2 兼顾两者。

## 平台支持

| 平台 | 实现 | 开机自启 | 状态 |
|---|---|---|---|
| **macOS** | pf（封外部 v4 DNS）+ networksetup DNS + launchd 守护 | LaunchDaemon | ✅ 实机验收通过 |
| **Windows** | NetFirewall 封外部 v4 DNS + DnsClient API + 计划任务（SYSTEM） | ScheduledTask | ✅ CI 验证（API 级） |
| **Android** | 原生 VpnService 配置真实 DNS；IPv4/IPv6 流量由系统直连 | 前台服务 + BOOT_COMPLETED + NetworkCallback | 见 [Android 验证说明](android/TESTING.md) |

## macOS 使用

```bash
cd macos
sudo ./v6on.sh                        # 开启 v6 优先
sudo ./autostart/install-launchd.sh   # + 注册开机自启守护
sudo ./autostart/uninstall.sh         # 卸载守护并还原
sudo ./v6off.sh                       # 回滚（守护自动挂起 30 分钟）
./test-suite.sh                       # 12 项生效性验证
```

配置文件 `anchor-v6only`；日志 `/var/log/v6only.log`；状态标记 `/var/run/v6only.active` / `v6only.suspend`。

## Windows 使用（管理员 PowerShell）

```powershell
cd windows
.\v6only.ps1 -On         # 开启 v6 优先
.\v6only.ps1 -Install    # + 注册 SYSTEM 计划任务（开机自启 + 5 分钟自愈）
.\v6only.ps1 -Off        # 回滚（守护挂起 30 分钟不干预）
.\v6only.ps1 -Test       # 生效性验证
.\v6only.ps1 -Uninstall  # 卸载还原
```

配置在 `%ProgramData%\v6only\`（日志/标记）；防火墙规则 `v6only-block-external-dns`。

## Android 使用

1. 安装 `v6only.apk`（本地构建：`cd android && ./build-apk.sh`），打开应用并点击「启动服务」授予 VPN 权限。
2. 默认自动模式：校园 DNS（`202.112.128.50/51`）、`buaa.edu.cn` 搜索域或 BUAA Wi-Fi 名称匹配时连接；离开校园网后断开 VPN，**前台服务继续监听**。普通 `10.x` 私网、蜂窝网络、VPN 自身不再作为校园网证据。
3. 若网络未提供校园 DNS／域名，可通过「授权校园 Wi-Fi 名称识别」授予精确位置权限并打开系统定位；后台识别新接入的 Wi-Fi 还需在系统位置权限中选择「始终允许」。应用只读取 Wi-Fi 名称，不读取坐标。SSID 不可读取时，界面会显示未识别到；可关闭自动模式使用手动连接。
4. 关闭自动模式会立即切换到手动连接；点击「停止服务」同时停止 VPN 和自动监听，不会因网络变化自行重启。下次启动恢复保存的模式。
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

[.github/workflows/ci.yml](.github/workflows/ci.yml) 三个 job：

- **windows-ci**（windows-latest）：PowerShell AST 语法解析、关键函数存在性、
  真实防火墙/计划任务/DNS API 冒烟（等价复现 v6only 的 API 调用链）
- **macos-shellcheck**（ubuntu-latest）：macOS 脚本静态检查
- **android-build**（macos-latest）：无 gradle 流水线（aapt2+javac+d8+apksigner）真实构建 APK 并验签，产物上传 Artifact

## 目录

```
macos/       pf anchor + 开关脚本 + launchd 守护 + 验证套件
windows/     v6only.ps1（单文件全功能）
android/     原生 APK 工程（无 gradle 构建流水线）
.github/     CI
```

## 免责声明

本项目按 AS IS 提供，仅供学习研究。使用者需自行承担合规责任，
遵守所在学校/单位《上网须知》及相关规定。
