# V6Only

macOS 2.1.6：默认启用网易云音乐 `m701/m801` 官方音频 CDN 的 IPv6 解析，动态选择移动/联通节点，保留原始 HTTPS 校验。详情见 [网易云 IPv6 说明](docs/netease-ipv6.md)。

IPv6 转发与流量记录工具，提供 macOS、Android 和 Windows 桌面/移动应用。

[下载安装包](https://github.com/y38501148-max/v6only/releases/latest) · [Android 使用说明](android/README.md) · [桌面版说明](desktop/README.md)

| 平台 | 安装包 | 支持范围 |
| --- | --- | --- |
| macOS | DMG | Apple Silicon，macOS 12+；当前控制器面向 BUAA 校园 Wi-Fi/en0 |
| Android | APK | Android 10+，arm64-v8a / x86_64 |
| Windows | MSI | Windows 10 1903+ / Windows 11，x64 |

安装后开启连接，可查看当前连接使用的实际 IPv4/IPv6 地址，并按时间段查看上传、下载及总流量，导出 CSV。关闭窗口后后台继续运行；在应用内停止连接会恢复系统网络。

## 网络行为

目标有 AAAA 地址时只连接 IPv6，不因连接失败而回退 IPv4；成功确认没有 AAAA 的目标允许 IPv4。公共 DNS 补充查询用于解决部分网络 DNS 隐藏视频 CDN 的 IPv6 地址问题。2.1.1 起，网络 DNS 已成功确认无 AAAA 时，补充查询最多等待 1 秒，公共 DNS 故障不再丢弃有效答案；两组 DNS 都失败仍报错。2.1.2 的 Windows、Android 和 macOS 启动配置同时保留 IPv4/IPv6 补充 DNS，并行查询 TCP/UDP，补充查询预算为 1.5 秒，容纳约 1 秒的 TCP 重传，同时避免某一 DNS 传输通道超时或提前返回空答案造成视频误走 IPv4；视频本身仍按 AAAA 结果走 IPv6。网络本身需要具备可用 IPv6，工具不能让只有 IPv4 的远端服务器凭空支持 IPv6。

ChatGPT / OpenAI 相关域名保持 IPv4。当前 macOS 版本保留原有 127.0.0.1:7890 HTTP 代理例外；Android 和 Windows 使用直接 IPv4 例外。工具不会提供额外的跨地区代理服务。其他 VPN、加密代理、ECH 或无法识别域名的连接有相应限制，详见平台说明。

流量记录为经过核心的实际套接字字节，按 IPv4/IPv6 和上传/下载拆分。SQLite 历史在停止连接后保留；自定义时间范围为左闭右开。记录不含 IP/链路层报头和重传，不能直接当作运营商或校园计费账单。

## 安卓后台设置

识别华为、荣耀、小米 / Redmi / POCO、iQOO、vivo、OPPO、一加、realme、三星，提供各品牌的自启动/后台管理入口以及通用电池优化、VPN 和应用设置入口。系统版本不同可能禁止厂商页面直接打开，此时会回到应用设置。开机恢复、START_STICKY、网络恢复和系统始终开启 VPN 均支持；首次 VPN 授权及厂商后台权限需要在手机上由用户设置。

华为仅指支持 Android APK 的 EMUI / HarmonyOS 系统；纯 HarmonyOS NEXT 不支持本 APK。厂商权限不能由普通应用自行授权，也不能保证在系统强制停止、厂商清理或未开放后台权限时持续运行。

## 开发和验证

Go 核心位于 `core/`，Tauri 2 桌面界面位于 `desktop/`，Android 原生界面与 VpnService 位于 `android/`。Windows 使用 Wintun；MSI 注册本机后台服务，卸载时停止服务并恢复应用接管的 DNS、路由。

```sh
cd core
go test -race ./...
go vet ./...
cd ..
python3 -m unittest discover -s tests -p test_macos.py
bash android/test.sh
node --check desktop/ui/app.js
node --test desktop/tests/*.test.cjs
```

macOS 构建：`bash scripts/build-desktop-macos.sh`。Android 构建：`bash android/build-apk.sh`，需要 JDK 17+、SDK API 36、NDK 29；正式发布可以通过 `V6ONLY_KEYSTORE`、`V6ONLY_STORE_PASSWORD`、`V6ONLY_KEY_PASSWORD` 指定签名密钥。密钥不进入 Git。

Windows 构建：在 Windows 上执行 `scripts/build-desktop-windows.ps1`，需要 Go、Rust MSVC 和 Node。GitHub Actions 提供 MSI 构建，以及实际安装、后台服务 IPC、Wintun、流量持久化和卸载恢复验证。仅一次性 CI 虚拟机运行修改网络的集成测试。

当前 macOS 应用使用本地签名，尚未完成 Apple 公证；Windows MSI 尚无发行者代码签名证书。下载后请核对 Release 附带的 SHA256 校验值。源码采用 MIT；第三方依赖遵循各自许可证，Windows 安装包包含 Wintun 许可证。
