# V6Only Android 2.1.1

原生 Android 界面 + VpnService 后台服务，复用桌面版 Go 转发核心。支持 Android 10 及以上；APK 包含 arm64-v8a（iQOO 15）和 x86_64。编译/目标 API 36，原生 ELF 已检查为 16 KiB 对齐。

## 安装和使用

安装 APK，首次打开后点击“启动服务”，完成 Android 的 VPN 连接授权。默认选择“开机启动”；首次完成授权并启动后，系统启动完成/解锁、应用更新会恢复此前启用的服务。“停止服务”会保存停止状态，随后开机也不会擅自重新连接。

退出界面或划掉最近任务后后台继续转发。进程被系统回收后使用 START_STICKY 恢复。网络丢失时进入等待，恢复后自动重建连接，Wi-Fi 和移动网络均可用。系统设置中的始终开启 VPN 也受支持；该模式的停止由系统 VPN 设置控制。手动“强行停止”、撤销 VPN 授权和其他 VPN 接管不做自动绕过。

后台通知无声音、无振动、无角标，仅保留 Android 要求的运行状态通知。不能保证完全隐藏系统 VPN 图标或通知。无定时广告弹窗，无上传统计的服务端。

## iQOO 15 后台设置

在手机设置中搜索“自启动”，允许 V6Only；在“电池 / 后台耗电管理”中找到 V6Only 并允许后台耗电；在最近任务中锁定应用。具体名称取决于 OriginOS 版本，可从应用内“后台运行”打开电池和应用设置。厂商的自启动开关无法由普通应用代替用户修改。

参考 vivo 官方说明：https://kefu.vivo.com.cn/robot/imgmsgData/2616a9cd7cd64a5083a264d16e5767da/index_1.html
参考 Android VPN 生命周期说明：https://developer.android.com/develop/connectivity/vpn

## 流量和检测

主页显示累计总额、IPv4/IPv6 分项；“流量记录”可选择今天、7 天、30 天、全部或自定义日期时间，并通过系统文件选择器导出 CSV。CSV 包含每个聚合时间点的四种上传/下载字节计数。

记录保存在应用私有目录的 traffic.sqlite，按秒写入，查询区间采用 [开始, 结束)，图表/记录展示按时段聚合。普通停止、退出和重启保留；卸载或清除应用数据会删除。计数为核心实际出站 TCP/UDP 载荷，含 TLS/DNS，不含链路头、重传和不经过本应用的流量，不等同运营商/校园网账单。正常停止落盘；异常断电最多可能丢失最后约一秒。

“查看连接”显示目标、实际远端 IPv4/IPv6 地址及上传下载量，支持哔哩哔哩筛选。连接详情只保留在内存中，重启清空。

## 路由和限制

有 AAAA 的目标仅连接 IPv6，失败不退回 IPv4；确认无 AAAA 的目标允许 IPv4。网络 DNS 漏掉公网 AAAA 时通过公共 DNS 补充查询；网络 DNS 已成功返回无 AAAA 时，补充查询最多等待 1.5 秒，公共 DNS 不通不会阻断已确认的 IPv4 目标。两组 DNS 都失败时仍报错。校园内网名称保留网络 DNS。补充 DNS 同时尝试 IPv4/IPv6、TCP/UDP。当前物理网络必须具有可用的全球 IPv6 地址和默认路由，否则暂停接管并保留系统网络；IPv6 恢复后自动重新接管。已解析的 IPv6 CDN 节点连接缓慢时，会补查其他 IPv6 节点，仍不回退 IPv4。

Android 版对 ChatGPT/OpenAI 域名禁用 IPv6，以 TCP/IPv4 连接。这是 IPv4 直连，并未内置桌面 iKuuu 代理：如果手机网络无法直连 ChatGPT，还需要可用的代理方案。macOS 当前既有 IPv4 代理设置不受安卓版影响。

Android 同一用户同时只允许一个系统 VPN，不能与另一个 VPN/TUN 代理并行运行。应用内加密代理、私有 DNS、ECH、裸地址可能使域名不可识别；连接列表应以最终实际地址为准。纯 IPv4 下载源不能凭本地客户端变成原生 IPv6，需要另外的 IPv6 中继。

## 构建和验证

```sh
bash android/build-apk.sh
bash android/test.sh
go -C core test -race ./...
ANDROID_SERIAL=emulator-5580 V6ONLY_TEST_SUITE=tunnel bash android/device-test.sh
ANDROID_SERIAL=emulator-5580 bash android/ui-test.sh
bash android/build-tests.sh
adb -s emulator-5580 install -r android/build/instrumentation/tests.apk
adb -s emulator-5580 shell am instrument -w edu.buaa.v6only.tests/.StartupSmoke
ANDROID_SERIAL=emulator-5580 python3 android/tests/device/lifecycle-test.py
```

设备脚本仅用于独立模拟器，不能直接对个人手机运行。2.1.0 已在 Android 16 模拟器验证真实 TUN + JNI 转发、IPv6/IPv4 选择、ChatGPT IPv4、IPv6 失败不回退、统计范围/停止后持久化、亮暗主题/大字体/横屏、全网连接、任务移除、网络重连、进程恢复和实际系统重启自启动。iQOO 15 真机未连接，实际校园/蜂窝 IPv6 可用性和 OriginOS 长期后台行为仍需在手机上确认。

构建默认使用本项目本地签名，保留 android/debug.keystore 才能制作可覆盖安装的后续版本；签名私钥不随源码包分发。发布者可用 V6ONLY_KEYSTORE / V6ONLY_STORE_PASSWORD / V6ONLY_KEY_PASSWORD 配置自己的签名。原生依赖的许可随 APK 放在 assets/third-party。

## 2.1.0 多品牌后台设置

“后台运行设置”自动识别华为、荣耀、小米 / Redmi / POCO、iQOO、vivo、OPPO、一加、realme、三星。先打开系统提供的厂商管理页；入口被禁用或因系统更新不存在时，回到通用应用设置。也可打开电池优化、始终开启 VPN 和应用详情。

华为/荣耀：应用启动管理中关闭自动管理，允许自启动、关联启动、后台活动。小米：允许自启动、省电无限制。vivo/iQOO：允许自启动与后台高耗电。OPPO/一加/realme：允许自启动、后台活动，取消耗电限制。三星：加入从不休眠的应用。各品牌可在最近任务锁定 V6Only。

这些入口不能代替用户授权，也不能绕过厂商清理、系统强制停止或与其他 VPN 的互斥限制。厂商识别与入口回退已在自动测试中覆盖；真实品牌手机仍需实机验证。华为仅支持可安装 Android APK 的系统，纯 HarmonyOS NEXT 不支持。

## 2.1.1 IPv4 连通性修复

修复 2.1.0 把公共 DNS 当作必需依赖的问题：网络 DNS 已给出正常 A 和无 AAAA 答案，公共 DNS 被拒绝、超时或返回 SERVFAIL 时，不再把整个 Android DNS 答案转换为 SERVFAIL。已查到 AAAA 的目标仍保持仅 IPv6，不在连接失败时回退 IPv4。模拟器隧道用例现在显式配置不可用的补充 DNS，覆盖 IPv4 TCP/UDP、双栈 IPv6、统计和停止恢复。版本码 9，签名沿用 2.1.0，可覆盖升级。
