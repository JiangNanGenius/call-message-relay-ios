# CallRelay

一个用于自有 **Linux 蜂窝电话网关**的原生 iPhone 客户端。SIM 和蜂窝模块连接在
Linux 主机上，iPhone 通过 CallKit 与原生 WebRTC 接打网关 SIM 的电话。
默认界面语言为简体中文。

首版已实现：Ed25519 一次性配对与网关身份绑定、Keychain 私钥/令牌、HTTPS REST 与
授权 WebSocket 事件、令牌轮换与幂等、拨号 / **短信** / 最近通话 / 设置四个标签、
来电与通话控制、原生 WebRTC（PCMU 8kHz）音频、PushKit/CallKit 来电路径，以及
完全离线的 **演示模式**。界面跟随 iPhone 系统浅色/深色外观。网关协议参考
[CellBridge v2.0.6](https://github.com/mccding/CellBridge/tree/v2.0.6)。

本仓库只包含独立客户端，不含模块刷机资料、固件、云端凭据或私人设备数据。

## 网关运行平台

网关端基于 Linux，**不限定 H28K**。H28K 是参考部署设备；其他 ARM 或 x86 Linux
主机也可以作为部署目标，前提是具备所用模块的驱动、USB/串口访问、AT 控制和
UAC/ALSA 音频支持，并运行兼容的网关服务。本 App 通过 HTTP/WebSocket/WebRTC
与网关交互，不直接依赖主机型号或 CPU 架构。

当前协议参考 CellBridge v2.0.6，音频路径参考 QDC507 的 UAC 实现；其他主机或模块
需要核对服务与驱动兼容性。尚未逐一实测所有 Linux 平台。
iPhone App 本身需要 iOS 17+；Linux 指网关服务的运行平台。

## 功能范围

- **拨号**：Phone 风格拨号盘、线路与 SIM/注册/信号状态；已授权线路显示完整本机号码。
  默认拨出线路持久保存（设置页选择），拨号键盘可按次临时切换且不改变默认；默认缺失、
  停用或无外呼权限时必须显式选择，绝不静默改用其他线路。持有网关“管理号码”授权的密钥
  可在 App 内编辑本机号码或恢复 SIM 自动读取，改动保存在网关并对其他已授权手机生效。
- **短信**：按号码聚合的对话列表、对话气泡、新建短信（可粘贴收件人、多行正文）、
  打开对话自动已读；发送按网关真实状态显示排队/已提交/已发送/失败，**不显示虚假送达**；
  失败可重试——同一逻辑提交重试沿用同一幂等键，网关已持久化的失败短信则作为新逻辑
  提交重发（避免重放已存失败）；轮询+事件刷新，载入失败可重试，离线/空列表有明确状态。
  发送门槛是 SIM 就绪 + 已注册 + `sms=ready`，不依赖语音能力。
- **最近通话**：原生「通话」样式，圆形头像、灰字副信息、未接来电红色号码、
  蓝色回拨按钮，点按可拨号或发短信；按天分组。
- **联系人**：新增原生联系人页（系统 CNContactStore，含 iCloud 已同步的统一联系人）。
  仅在你点按授权后读取，准确处理未决定/拒绝/受限/iOS 18 受限访问；可搜索、选择号码
  拨号或发短信，并在最近通话/短信中显示联系人姓名。支持**非破坏性去重导出**：预览
  完全重复项与“共用号码但姓名不同”项（后者默认不合并），用系统
  `CNContactVCardSerialization` 生成真实 vCard(.vcf) 分享；系统通讯录不会被修改。
- **垃圾拦截（短信/来电）**：本地、可编辑、默认保守——未知号码本身**绝不**算垃圾；
  规则包含完全号码、号码前缀、关键词、正则、信任号码/关键词，以及 4 组可选中文/英文
  预设（贷款理财、赌博刷单、营销退订、English promo，全部默认关闭）。含 4–8 位数字的
  验证码/取件码等结构化通知受保护，不会因为含“订单/验证码”字样被误拦。命中短信进入可
  恢复的「垃圾信息」隔离区（可删除/标记为已知发件人/恢复），不删除网关数据。来电支持
  手动/导入名单的**精确号码**匹配，可选择仅标记或在系统来电报告后立即结束（始终先满足
  PushKit/CallKit 上报要求；客户端拦截不能保证运营商侧不响铃）。可粘贴、从文件或 HTTPS
  链接导入号码名单（无鉴权头、不上传任何内容、2MB/5 万号码上限、失败保留上一份），随
  App 内置一份 **Apache-2.0、2020 年、34 个号码**的中文历史社区名单，默认关闭、
  仅标记，可查看来源/日期/数量后自行启用拦截。
- **可靠重连**：事件流与状态轮询采用带抖动的有界指数退避；网络恢复（NWPath）和回到
  前台立即重试，429 遵循 Retry-After，瞬时 5xx/网络错误退避，4xx/授权失效停止自动重试；
  WebSocket 重连/前台后做快照对账（按稳定 id 幂等合并，绝不重复发短信/拨号）；待发短信
  持久化到受保护文件并在短信线路恢复后用同一幂等键补发；通话中 ICE 短暂断开进入「恢复中」
  并给同一 PeerConnection 一个有界恢复窗口，超时才如实结束，绝不自动重拨。
- **iCloud 同步（可选）**：同一 iCloud 账号下用**私人数据库 + `CKRecord.encryptedValues`**
  （CloudKit 服务端静态加密字段；属于“加密存储/at rest”，并非在任何账号设置下都保证
  端到端加密）同步短信/通话历史与本地过滤规则，按网关隔离（历史互不相混；云记录逻辑 id
  带网关 scope 前缀，两个网关的相同原始 id 也不会互相覆盖）、可复制的墓碑记录删除、
  离线排队、乐观并发（change tag / serverRecordChanged 冲突收敛）、增量 token（过期自动
  全量重置基线）、账号切换世代隔离；每次同步先拉取后推送，下载的历史只读，绝不会因此再
  发短信或拨号；不同步配对私钥、网关令牌或设备待发短信。自签名/Feather 基线没有生效的
  iCloud 权限：开关先解析 embedded.mobileprovision（必须精确包含配置容器且声明 CloudKit
  服务），再在 ObjC `@try/@catch` 保护下用 `CKContainer.accountStatus`/`fetchUserRecordID`
  实测生效权限与账号身份（描述文件权限可能比实际签名权限更宽；也不使用 iCloud Drive 的
  ubiquityIdentityToken 判断 CloudKit 登录）；权限缺失时安全显示“不可用”，不会崩溃。
  需用含 CloudKit 能力的描述文件重签后才能真正双机同步。联系人的 iCloud 同步由系统
  “iCloud 联系人”提供。

- **设置**：连接状态（含短信能力）、铃声与来电说明（CallKit 系统响铃、不自行响铃/抢音频）、
  网关信息、解除配对（删除本机私钥与令牌）、演示模式入口。
- **配对**：粘贴或扫码网关一次性配对数据；Ed25519 私钥留在 iPhone
  （Keychain `afterFirstUnlockThisDeviceOnly`），先匿名校验网关 id/公钥指纹再发证明。
- **通话**：CallKit 系统通话界面，拨出/接听/拒绝/挂断/静音/DTMF/扬声器；真实“已接通”
  需要网关 `active` 且媒体连通，REST 201 不会显示已接通。
- **音频**：stasel/WebRTC M151，非 trickle ICE，与上游一致的 **PCMU/8kHz**，开启
  WebRTC 回声消除/降噪/自动增益，音频会话遵循 CallKit 所有权。
- **推送**：PushKit VoIP + 普通 APNs 令牌注册；非 UUID 的网关呼叫 id 用确定性
  UUIDv5 稳定映射，推送/事件/轮询收敛到同一通系统通话。
- **演示模式**：内存假网关，保留的 555 模拟号码，绝不联网、发短信或触发真实来电；
  可在设置中模拟收发短信与发送失败，方便走查全部状态。

## 系统电话集成

- 来电响铃与系统通话界面完全由 **CallKit** 负责，App 不自行播放铃声或抢占音频；
  音量、听筒/扬声器/蓝牙遵循系统通话音频会话。
- 拨出通话通过 `INStartCallIntent` 捐赠进入系统电话「最近通话」，从系统电话/联系人
  入口点回时经同一网关拨号路径处理；未配对或离线时给出解释，**不会**改用蜂窝 `tel:`
  直接呼出。视频 Intent 不支持。
- 成为系统「默认通话 App」需要 iOS 18.2+ 并在签名描述文件中启用
  `com.apple.developer.calling-app` 能力后自行核验，侧载预览包未声明该能力。

## 快速开始

需要 Xcode（部署目标 iOS 17+）、XcodeGen。首次：

```sh
./Scripts/bootstrap.sh     # 下载并校验固定校验和的 WebRTC M151
xcodegen generate         # 生成 CallRelay.xcodeproj
```

构建、测试、无签名真机编译、签名与 APNs 说明见 [BUILD.md](BUILD.md)。
协议事实、安全设计与“已验证/未验证”边界见 [PROTOCOL.md](PROTOCOL.md)。

## Feather 安装源

当前预览版：[CallRelay 0.1.0](https://github.com/JiangNanGenius/call-message-relay-ios/releases/tag/v0.1.0)，支持 iOS 17+。

在 Feather「源」中添加：

```
https://raw.githubusercontent.com/JiangNanGenius/call-message-relay-ios/main/feather.json
```

源提供首版预览的**未签名 IPA**，由 Feather 使用你自己的证书与描述文件签名后安装。
无需上架 App Store。下载地址、版本、大小与 SHA-256 取自 GitHub Release 的实际产物。
后台 VoIP 来电仍需匹配 Bundle ID、Push Notifications 描述文件和自有 APNs 服务；
重新签名安装成功不代表后台推送或真实网关通话已经验收。

本版来自固定源码 `0972a995fe9704f74bbb0df0786ff9b77aa452f2`；
[发布 CI](https://github.com/JiangNanGenius/call-message-relay-ios/actions/runs/36869469687)
通过 174 项单元测试、白天和夜间各一遍完整短信界面流程及 iPhone Release 构建，
0 失败、0 测试进程重启。模拟器截图使用虚构内容，日夜界面已目视检查。

| 界面 | 白天 | 夜间 |
| --- | --- | --- |
| 拨号 | <img src="https://github.com/JiangNanGenius/call-message-relay-ios/releases/download/v0.1.0/callrelay-dialer-light.png" width="220" alt="白天拨号界面"> | <img src="https://github.com/JiangNanGenius/call-message-relay-ios/releases/download/v0.1.0/callrelay-dialer-dark.png" width="220" alt="夜间拨号界面"> |
| 短信 | <img src="https://github.com/JiangNanGenius/call-message-relay-ios/releases/download/v0.1.0/callrelay-messages-light.png" width="220" alt="白天短信列表"> | <img src="https://github.com/JiangNanGenius/call-message-relay-ios/releases/download/v0.1.0/callrelay-messages-dark.png" width="220" alt="夜间短信列表"> |

## 音质边界（重要）

当前**网关实现**（CellBridge v2.0.6 的 UAC + WebRTC）固定 **8kHz / PCMU 64kbps
窄带**，即传统电话音质，**不是 HD/宽带**。QDC507 硬件或刷机后固件是否支持 16kHz
宽带 / 运营商 AMR-WB 尚未验证；若将来实测支持，需要网关与 App 整条链路升级编码协商，
首版不扩展宽带编码，也不对延迟或 DSP 效果做无依据承诺。

真机仍需逐项验收：双向可听、回声/降噪、听筒/扬声器/蓝牙路由、音频中断恢复，以及
Wi‑Fi/蜂窝切换和弱网（含 TURN 中继）。

## 尚未验证的关卡

- 真实网关短信：收件、中文与长短信、发送失败重试、未读/已读同步。

- 真实 H28K/QDC507 的 AT/UAC 与双向音频、私有 TURN/coturn 中继。
- 自有云受限控制通道与 APNs Push Broker；真机锁屏 VoIP 来电（sandbox/production）。
- 物理 iPhone 的签名、描述文件与后台 VoIP 行为。模拟器与测试目标已编译通过，测试执行结果以本仓库 CI 为准；
  但 CallKit/PushKit/真实音频必须在签名真机与真实网关上验收。
- 垃圾规则为本地启发式预设，非“认证骚扰号码库”；内置中文名单是 2020 年历史归档，
  不代表当前仍为骚扰号码，也不做号段/归属地式的宽泛拦截。客户端拦截发生在网关来电到达
  之后，不能保证运营商线路不响铃；系统电话/信息过滤扩展（CallDirectory/IdentityLookup）
  不在本 App 范围。
- 通讯录访问与 vCard 导出、CloudKit 双机同步需要在含对应能力的签名真机上验收；
  未签名 Feather 包中 iCloud 开关会显示不可用，联系人 iCloud 同步依赖系统设置。

## 使用范围与许可证

本项目源码公开，采用 **PolyForm Noncommercial 1.0.0**，仅授权非商业用途；完整条款见
[LICENSE](LICENSE)。第三方组件（Google WebRTC 等）沿用
各自许可证，见 [ThirdPartyNotices.md](ThirdPartyNotices.md)；接口参考不代表复制或
重新授权上游代码。内置中文历史骚扰电话名单来自 blessing-gao/rubbish-phone
（Apache-2.0，2020 年归档，34 个号码），默认关闭，归属与许可证见
`CallRelay/Resources/Licenses/SpamList-CN-Historical-NOTICE.txt`。垃圾拦截预设关键词
为本项目原创编写，灵感仅来自公开的本地过滤项目（boommanpro/ios-sms-guard、
adibendahan/SimplyFilterSMS、SysAdminDoc/CallShield）的分类思路，未复制其规则或号码库。

项目用于自行构建与安装，不计划上架 App Store。
