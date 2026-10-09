# V6Only 2.1.0 for macOS

Tauri 2 桌面应用，面向当前校园网 Wi-Fi/en0，使用已有的 Go TUN 核心。应用在 `/Applications/V6Only.app`，启动台中搜索 V6Only。

## 使用

首次启动点击“安装并启用”，在 macOS 自带弹窗完成管理员验证。之后可在应用内开启/关闭转发、检测任意 HTTP(S) 站点、选择时间段查看流量、导出 CSV 到“下载”。后台使用 launchd 常驻，关闭或退出窗口不停止转发与记录；“关闭转发”恢复此前的 DNS/代理开关/自有路由并暂停自动启用。

## 策略

A 与 AAAA 同时查询。域名有 AAAA 时，只尝试 IPv6 地址；IPv6 全部失败也不允许 IPv4。DNS 查询失败不会被当成 IPv4-only。只有 DNS 成功确认没有 AAAA 时才允许 IPv4。TCP、UDP 都遵循此规则；移除了桌面端绕过域名策略而连接原始 IPv4 的兜底路径。

裸 IPv4 地址没有域名可查询，按明确指定地址连接。HTTP Host、TLS SNI 和 DNS 缓存用于还原目标域名。其他 VPN、应用内加密代理、ECH 及无法识别的目标不能保证还原内部域名。启用时暂时关闭 Wi-Fi 的全局 HTTP/HTTPS/SOCKS 代理开关，并开启本机 PAC，仅把 ChatGPT/OpenAI 相关域名交给现有 127.0.0.1:7890 代理；关闭时恢复原有代理开关与 PAC URL，不删除代理服务器配置。用户之后手动启用的代理不会被关闭操作覆盖。

## 流量

记录真实物理出站套接字实际成功读写的 TCP/UDP 字节，按远端地址族分为 IPv4、IPv6，各含上传/下载。包含经核心查询的 DNS 数据和 TLS 握手/加密负载。计数不读取网络接口总字节，不把 TUN 入口地址误当成真实出口，也不重复计算来回转发。

SQLite 数据库位于 `/var/db/v6only/traffic.sqlite`，后台按秒存储、WAL + FULL 同步，正常退出落盘；异常断电/强制终止最多可能丢失最后约一秒的未落盘计数。历史没有自动删除。统计从首次启用开始，无法补出此前流量。不计 IP/链路报头、重传、未经过核心的流量，不能等同校园计费账单。自定义时间范围采用 `[开始, 结束)`；图表和导出按分钟、小时或日汇总，但总额按秒记录筛选。

后台控制只开放本机 Unix socket `/var/run/v6only-desktop.sock`，权限 0600，限定安装时的桌面用户。窗口内不提供任意 shell 执行接口。流量记录不存访问内容；最近连接为内存中的最多 512 条，不把访问域名写入统计库。

## 构建

```sh
cd core
go build -trimpath -ldflags='-s -w -X main.version=2.1.0' -o ../macos/v6core ./cmd/v6core
go build -trimpath -ldflags='-s -w' -o ../macos/v6service ./cmd/v6service
cd ..
cp macos/v6core macos/v6service macos/*.sh macos/anchor-v6only desktop/src-tauri/resources/macos/
cd desktop
npm ci
npm run build
```

需要 Rust、Go、Node 和 Xcode Command Line Tools。构建过程采用 Tauri 原生 macOS `.app` 打包；见 [Tauri 官方文档](https://v2.tauri.app/distribute/macos-application-bundle/)。本机应用为本地签名，不是公开发行的公证包。

## 验证

```sh
cd core
go test -race ./...
go vet ./...
cd ..
python3 -m unittest discover -s tests -p test_macos.py
node --check desktop/ui/app.js
```

`tests/tunnel-macos.sh` 只允许一次性 GitHub CI 虚拟机运行，不能在日用 Mac 执行。

## Bilibili 视频与 IPv6

2026-10-08 本机实测：校园 DNS 对 `cn-bj-fx-01-01.bilivideo.com`、华为/腾讯 UPOS 等 CDN 不返回 AAAA；通过 IPv6 查询阿里公共 DNS `2400:3200::1 / 2400:3200:baba::1` 能得到真实 IPv6 地址。对同一视频原始签名路径进行 HTTPS Range 验证，原 CDN 与两个 UPOS 节点均通过证书校验，返回 206、65536 字节，内容 SHA256 一致。前面只按校园 DNS 判断“没有 AAAA”的行为因此不能满足视频走 IPv6的目标。

2.0.2 对公网域名先使用校园 DNS 已有的 AAAA；校园 DNS 未给出 AAAA 时，通过 IPv6 公共 DNS 再查一次，A 查询继续使用校园 DNS；`buaa.edu.cn` 及其子域名保留校园 DNS，避免影响校园门户。校园网实测公共 IPv6 DNS 的 UDP 偶尔超时、TCP 正常；因此公共 IPv6 DNS 优先 TCP，UDP 作为后备，并修复旧版 UDP 失败后未继续尝试 TCP 的问题。公网 AAAA 查询失败时拒绝当作 IPv4-only；查到 IPv6 后不允许 IPv4 回退。无需更换视频 URL、安装根证书或解密 HTTPS。

双栈文件下载也按此策略走 IPv6。真正只有 IPv4 的文件服务器仍需要 IPv6 代理或 NAT64 中继，单独改变本机设置无法创建远端 IPv6 服务。其他 VPN/应用自身的加密代理可能隐藏最终域名，不能用它们的 IPv4 出口推断视频直连的协议。

网络概览下方可筛选“哔哩哔哩 / 视频 CDN”，按每条连接实际上传、下载排序。该列表是本次核心运行期间最近 512 条连接的诊断视图，不等同全部历史站点流量；完整 IPv4/IPv6 历史总额在“流量记录”中。

2.0.1 同时修复全部 TCP 端口的 HTTP Host/TLS SNI 识别、代理状态查询/完整校验，以及 Wi-Fi 地址/网关变化后重启核心和自有路由清理。启用后应刷新视频页面，让新连接使用新的网络配置。

## ChatGPT IPv4 例外（2.0.3）

`chatgpt.com`、`openai.com`、`oaistatic.com`、`oaiusercontent.com` 及其子域名使用现有 iKuuu IPv4 代理，系统 PAC 对其他目标返回 DIRECT。核心对此类目标隐藏 AAAA、拒绝 UDP，并使用 IPv4 loopback HTTP CONNECT 连接 127.0.0.1:7890，不尝试 IPv6、也不回退到 IPv6；代理不可用时明确报错。

当前 iKuuu 实测物理出站为 IPv4。代理节点如果后续被用户更换成 IPv6 节点，远端传输协议会随节点改变；“IPv4 代理”连接行表示本机到现有代理的方式，真实物理代理上游连接的字节在核心出口单独记录，不重复计数。请保持现有 iKuuu 运行。


DNS 按 TTL 缓存并合并同一问题的并发请求，避免大量重复 AAAA 查询拖慢播放；公共 IPv6 DNS 故障不会被误判为仅 IPv4。

## Windows 2.1.1

Windows 10 1903+ / Windows 11 x64，通过 MSI 安装 Tauri 界面、Wintun、Go 转发核心和 V6Only 系统服务。安装时由 Windows 提供管理员授权；之后普通用户可在界面开启、停止、检测和导出流量。后台启动记住上次开启状态，关闭窗口不会停止连接。卸载先停止服务，还原自有 DNS/路由，再删除服务。历史数据库保留在 `%ProgramData%\v6only\traffic.sqlite`，便于重新安装后查看。

Windows 默认覆盖活动物理网卡，使用该网卡原有 DNS 和公共 IPv6 DNS 补充查询。ChatGPT 使用直接 TCP IPv4 例外。不会替代已有的地区访问代理；其他 VPN 的兼容性需要实机检查。

后台通过本机命名管道通讯，拒绝网络登录访问，只向本地交互用户开放固定的状态、开启、停止、统计、检测操作，不允许任意命令或路径。应用和服务文件位于受系统保护的 Program Files；网络恢复与卸载验证在 GitHub Windows 虚拟机运行。

构建：`scripts/build-desktop-windows.ps1`。macOS DMG：`bash scripts/build-desktop-macos.sh`。

## 2.1.1 Android / Windows 修复

修复 Windows PowerShell 将连接数组序列化为 `{value: [], Count: 0}` 后，界面 `.filter()` 报错、误把已运行服务判为未安装并提示管理员授权的问题。服务现在输出标准 JSON 数组；界面同时兼容旧服务的包装格式。

Windows 的“安装并启用”现在调用随 MSI 安装的固定脚本：按需请求 UAC 授权，创建缺失的 V6Only 服务或启动被停用的服务，等待服务运行，再启用转发。日常开启/关闭仍通过本机服务进行，无需把整个界面长期以管理员身份运行。状态读取失败保留具体错误，不再一律解释成缺少管理员权限。

修复 Wintun 已被 WMI 枚举但尚未 Up / 未完成 IPv4、IPv6 注册时重试不等待的问题。CI 验证服务停止/禁用和注册删除后的恢复、真实 Wintun IPv4 转发及卸载网络恢复。

补充 DNS 查询现在是有时限的补充步骤：网络 DNS 已确认无 AAAA 而公共 DNS 不通时，保留有效答案；两组 DNS 都失败仍报错，已查到 AAAA 的目标仍禁止 IPv4 连接回退。该修订适用于 2.1.1 构建的核心；本次发布 Android APK 和 Windows MSI，macOS 安装包仍为 2.1.0。

## Windows 2.1.5

修复桌面服务在转发初始化失败后永久暂停的问题：失败时回滚网络配置，保留用户的启用状态，冷却 60 秒后由后台检查重新尝试。升级时自动清理旧版本失败后遗留的空暂停标记。手动关闭、有效时间戳暂停及旧版校园网守护的行为保持不变。

本次发布 Windows x64 MSI；Android 和 macOS 继续使用 2.1.4 安装包。Windows 构建验证包含 PowerShell 5.1/7 启动重试回归，以及 MSI 安装、服务修复、真实 Wintun 转发、卸载与网络恢复。
