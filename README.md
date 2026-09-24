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
| **Android** | 原生 VpnService：v4 进 TUN 白名单放行 10/8，v6 不进 TUN 走原生栈 | BOOT_COMPLETED + NetworkCallback | ✅ 模拟器验收通过 |

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

1. 安装 Release 里的 `v6only.apk`（或自行构建：`cd android && ./build-apk.sh`）
2. 打开 APP → 点一次「启动 VPN」（系统一次性 VpnService 授权）
3. 之后全自动：开机自启 → 检测到校园网（DNS 后缀/网关/SSID 多信号）→ 静默接管；离开 → 静默还原
4. 「自动模式」可一键关闭变纯手动

技术要点：`addRoute(0.0.0.0/0)` 吸走全部 v4、用户态 pump 白名单放行 `10/8`、
API 33+ 用 `excludeRoute` 硬排除校内段；**v6 不 addRoute，完全不进 VPN**（零开销）；
校园网检测用 `LinkProperties`（DNS/网关/域名）而非 SSID（Android 10+ 取 SSID 需定位权限且不可靠）。

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
