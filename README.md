# v6only 1.1.0 — 校园网 IPv6 优先转发

macOS、Android 和 Windows 使用同一个转发核心。识别域名后，**TCP 先尝试该域名的 IPv6 地址；IPv6 连接全部失败或超时后才尝试 IPv4**，不再由 IPv4 与 IPv6 竞速决定出口。只支持 IPv4 的站点仍可访问。

**仅校园网生效。** 手动模式也必须通过校园识别；离开校园网后恢复普通网络配置。正常家庭网络、热点和蜂窝网络不启用。普通 `10/8` 私网地址不作为校园网证据。

## 工作方式与边界

- 核心读取 A/AAAA，识别 HTTP Host、TLS SNI，建立实际出站连接。TCP 的单个地址族尝试预算为 5 秒，IPv4 不与 IPv6 同时竞速。
- macOS/Windows 保留真实 DNS 地址和回答，避免现有代理把虚拟地址发送到远端。共享 CDN IP 无法唯一确定域名时，不凭反向缓存猜测目标，优先读取 TLS SNI / HTTP Host。
- Android 的 VPN DNS 范围内使用虚拟 IPv4 地址映射域名；应用即使选择该 IPv4 地址，核心也会先连接真实 IPv6。出站套接字保护并绑定物理网络，避免返回 VPN。
- UDP 优先 IPv6；明确连接错误后可回退。QUIC/NTP 可在等不到回应时重试其他地址。普通 UDP 不因没有回应就把同一数据包重发到另一地址，避免重复执行应用操作。
- 未知 IPv4 QUIC 会触发丢包，常见浏览器会改用可识别域名的 TLS/TCP。自带加密 DNS、ECH、缓存、共享 IP、应用强制绑定物理接口，可能使部分连接无法识别或绕过转发。
- **远端加密代理内部连接、其他 VPN 和未知裸 IP 不能保证被强制改为 IPv6。** 核心只能控制自身看到并识别的目标；不能从浏览器本地显示的虚拟 IP 或 `127.0.0.1` 判断最终出口。DNS 查询失败或新的 CDN 地址不可达时，桌面端会尝试原目标地址保留连通性，诊断中单独标明该原因。

## 故障恢复

macOS 为核心添加限定物理接口的出口路由，避免全量路由接管后核心自身失去出口；关闭时仅删除本工具记录的路由。Windows 使用 Wintun，并等待网卡地址可用后再接管路由。桌面 DNS 不指向临时本机 DNS 进程，核心退出后仍可解析。

核心用真实 TCP 与 UDP/DNS 请求定期检查 TUN 数据通路。启动时允许 30 秒完成路由配置；运行后连续两次检查失败会退出核心/关闭 Android VPN。桌面守护随后撤销自身设置并暂停，需手动开启才重试。桌面首次应用还会检查校园门户和 Bilibili 的完整 DNS/TLS 连通性，失败即回滚，避免反复接管网络。

保留其他代理及防火墙规则，关闭时保留用户后来修改的设置。macOS 守护通常每 20 秒检查校园状态，离校恢复并非切网瞬间同步完成。

## 安装

下载 Release 中对应平台的安装包，并核对 `SHA256SUMS.txt`。macOS 包包含 Apple Silicon / Intel 通用核心；Windows 包为 x64；Android APK 支持 arm64-v8a / x86_64，最低 Android 10。

### macOS

解压后，在目录内运行：

```bash
sudo bash macos/install-launchd.sh
sudo bash /usr/local/lib/v6only/v6ctl.sh status
sudo bash /usr/local/lib/v6only/test-suite.sh
```

macOS 二进制为本地签名，未做 Apple 公证。安装器只配置 Wi-Fi/en0；源码构建先运行 `bash macos/build.sh`。PF 必须有系统 `com.apple/*` anchor 入口；已知旧版迁移使用 `--migrate-legacy`，空规则初装使用 `--initialize-pf`，其他自定义主规则需自行保留并接入。

```bash
sudo bash /usr/local/lib/v6only/v6off.sh       # 关闭并暂停 30 分钟
sudo bash /usr/local/lib/v6only/v6on.sh        # 校园内手动开启，也解除故障暂停
sudo bash /usr/local/lib/v6only/uninstall.sh  # 卸载并恢复本工具拥有的配置
```

配置快照在 `/var/db/v6only/original`，安装备份在 `/var/db/v6only/backups`。故障自动暂停使用 `/var/run/v6only.suspend` 空文件；正常手动暂停写入到期时间。若之前明确禁用了 launchd 服务，重新安装会保留该禁用状态，不自行解除。

### Windows

以管理员 PowerShell 在解压目录中运行：

```powershell
.\windows\v6only.ps1 -Install
.\windows\v6only.ps1 -Test
.\windows\v6only.ps1 -Off
.\windows\v6only.ps1 -On
.\windows\v6only.ps1 -Uninstall
```

发布包包含核心及 [Wintun 官方签名 DLL](https://www.wintun.net/)，构建脚本固定版本并校验 SHA-256。配置和快照位于 `%ProgramData%\v6only`。

### Android

安装 APK，启动服务并授权 VPN。自动模式在非校园网只监听，不建立 VPN；手动模式离校后停止。校园识别使用物理网络 DNS、域名或校园 Wi-Fi 名称，名称识别可选位置权限，应用不读取坐标。停止服务后不会因网络变化自行开启。

新 Release 使用与 1.0.1—1.0.3 相同的签名，可覆盖升级。自行构建的调试包通常不能覆盖 Release。iQOO/vivo 等设备仍可能需要允许自启动、后台运行；强行停止后需手动打开。普通模式不支持“阻止未通过 VPN 的连接”，离校时需要系统正常联网。

## 验证和开发隔离

**不要在日常使用的宿主机上试验默认路由、DNS 或防火墙接管。** 普通本地检查：

```bash
(cd core && go test -race ./... && go vet ./...)
python3 -m unittest discover -s tests -v
bash android/test.sh
```

系统测试：

- `tests/tunnel-linux.sh`：隔离网络命名空间，真实 TUN、DNS/TCP、UDP、TLS SNI、IPv6 优先、IPv4-only、IPv6 失败回退、退出恢复。拒绝普通宿主环境。
- `tests/tunnel-macos.sh`：仅 GitHub 托管 macOS 虚拟机运行，先测受控双栈，再测全量路由下的公网 HTTPS，关闭后检查恢复。
- `windows/integration-test.ps1`：仅 GitHub 托管 Windows 虚拟机运行，实际加载 Wintun，验证双栈、全量转发和退出恢复；不代表 Windows 校园实机验收。
- `ANDROID_SERIAL=emulator-5580 V6ONLY_TEST_SUITE=tunnel bash android/device-test.sh`：仅临时模拟器，使用生产版 TUN 建立、关闭与套接字保护代码。测试服务仅存在于 `v6only-fixture.apk`，生产 APK 不包含校园识别绕过入口。详见 [Android 测试说明](android/TESTING.md)。

校园物理网络、厂商后台限制和其他代理组合仍需各自环境验收。CI / 模拟器结果不等同于这些实机环境全部通过。

## 诊断和许可证

桌面运行时 `http://127.0.0.1:17890/flows?host=www.bilibili.com` 返回最近的内存连接记录，包括真实远端地址、TCP/UDP 地址族与回退原因。默认不将每个访问域名写入日志；`--log-flows` 可显式启用。只读状态接口绑定本机回环地址。

发布包携带依赖许可证；Android 内置于 APK 的 `assets/third-party`。项目采用 MIT License，第三方组件各自遵循其许可证。IPv6 可达性不代表校园流量计费规则。

[1.0.3 历史说明](docs/1.0.3.md)
