# CallRelay 发布流程（双变体，Feather 源纯原生）

每次更新同时发布两个**未签名**构建，共用同一营销版本与核心修复；Feather 安装源
永远只指向纯原生版。本文件是公开、可复现的发布流程；当前版本的实测证据记录在
工作区的 `evidence/h28k/pwa-notifications/`。

| 变体 | Xcode 配置 | 桥接 | 渠道 |
| --- | --- | --- | --- |
| Feather 纯原生 | `Release`（默认） | 无网页推送桥接 | GitHub Release 未签名 IPA + Feather 源；私有签名 IPA 只交给所有者 |
| App Store PWA | `Release-PWA` | 自托管 PWA Web Push 桥接：`callrelay://` 来电检查回链 | GitHub Release 未签名 IPA；App Store 仅在明确授权后提交 |

桥接由编译条件 `PWA_BRIDGE` 与 `Info-PWA.plist` 隔离；默认构建不含网页推送 UI、
deeplink 或桥接字符串。PWA 桥接不含 Bark、不含中央服务、不含第三方通知依赖：
每个网关在自己已有的 HTTPS 域名上托管可安装 PWA（manifest + service worker），
自持 VAPID 密钥并向自己的浏览器订阅发送标准 Web Push（RFC 8030 + VAPID +
RFC 8291 加密，使用经过验证的公开库）。App 只生成短时单次绑定码；浏览器订阅
密钥只保存在网关。

## 工具

- `Scripts/package-release-variants.sh` — 构建两个变体（`CODE_SIGNING_ALLOWED=NO`）、
  按版本打包 IPA、逐个校验并生成 `SHA256SUMS.public.txt`。
  默认把编译缓存放在 `~/Library/Caches/CodexBuild/callrelay/release-variants/`
  （可用 `DERIVED_DATA_ROOT` 覆盖）；`--app-native/--app-pwa` 可对已有构建产物
  只做打包+校验。
- `Scripts/verify-release-variant.sh` — 验证单个 `.app`/`.ipa`：native 必须无
  `CFBundleURLTypes`、无桥接字符串表、二进制无桥接符号；
  pwa 必须具备 `callrelay://` 与 `WebPushBridge.strings`；两者都必须未签名
  （无 `embedded.mobileprovision`、无 `_CodeSignature`），版本号可选断言。
- `Scripts/update-feather-source.py` — 从实际原生 IPA 生成/更新 `feather.json`：
  读取真实大小与 SHA-256，拒绝任何含桥接内容的 IPA，`--feed` 合并历史版本。
- `.github/workflows/build.yml` — 原生单元/UI 测试、两个变体的无签名真机构建、
  变体身份校验，并运行 Feather 生成器做纯原生自检。

## 发布步骤

1. 在 `project.yml` 同时更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`
   （两个变体共用），提交到 `main`。
2. 构建、打包、校验两个变体：
   ```sh
   ./Scripts/package-release-variants.sh
   # 或对已有构建：
   ./Scripts/package-release-variants.sh \
     --app-native <native CallRelay.app> --app-pwa <pwa CallRelay.app>
   ```
   产物形如 `build/feather-<version>-<build>/`：
   - `CallRelay-Feather-Native-<version>-<build>-unsigned.ipa`
   - `CallRelay-AppStore-PWA-<version>-<build>-unsigned.ipa`
   - `SHA256SUMS.public.txt`
3. 生成/更新 Feather 源（只能使用原生 IPA；脚本会拒绝任何含桥接的包）：
   ```sh
   ./Scripts/update-feather-source.py \
     build/feather-<version>-<build>/CallRelay-Feather-Native-<version>-<build>-unsigned.ipa \
     --tag v<version> --feed feather.json --output feather.json
   ```
4. 提交 `feather.json`/文档，打标签并推送：
   ```sh
   git tag v<version> && git push origin main v<version>
   ```
5. 创建 GitHub 预发布（保持与既有版本一致的 prerelease），只上传两个未签名 IPA
   与校验和：
   ```sh
   gh release create v<version> --prerelease \
     --title "CallRelay <version> (<build>)" --notes-file <release-notes.md> \
     CallRelay-Feather-Native-<version>-<build>-unsigned.ipa \
     CallRelay-AppStore-PWA-<version>-<build>-unsigned.ipa \
     SHA256SUMS.public.txt
   ```
   为避免与本地文件名混淆，上传时把 `SHA256SUMS.public.txt` 命名为 `SHA256SUMS`。
6. 用未登录下载复核：`shasum -a 256 -c SHA256SUMS`、逐一打开 Feather 源中的
   下载地址，并核对 `size`/`sha256`/`version` 与实际资产一致。

## 安全红线

- GitHub 公开资产只能包含两个未签名 IPA 与校验和：不得含
  `embedded.mobileprovision`、`_CodeSignature`、`.p12`/`.p8`、描述文件、设备列表
  或签名身份；发布前运行 `Scripts/verify-release-variant.sh` 验证。
- 私有签名 IPA 与 `.xcarchive` 只保留在所有者控制的私有位置，绝不进入公开渠道。
- Feather 源只能指向纯原生未签名 IPA；App Store/TestFlight 上传需要单独的明确授权。
- 已发布版本与其标签/资产视为不可变：下一个版本使用新的补丁版本号，不覆盖旧资产。

## 当前版本 (0.3.34 build 41)

- 0.3.21–0.3.34 为公开发布前的累计开发版本，本次公开发布包含其中的 App 侧
  修复与功能（联系人密钥隔离、vCard、告警、直连优先/中继横幅、音频会话生命周期等），核心变更：
  - 来电系统界面（LiveCommunicationKit）上报链路修复：重复 VoIP 推送只在
    “上报进行中 / 系统已接受 / 已无可用有界重试额度”时才去重；App 内追踪
    不再冒充系统接受。被拒绝或未决的上报可由后续推送有界重试；上报进行中
    到达的真实主叫号不再丢失，会立即刷新系统句柄或用于一次重试。
  - LCK 上报的接受/拒绝结果（仅 domain/code，无号码/联系人）写入脱敏诊断，
    下一次现场导出即可判定“无系统界面”是上报被拒还是系统未展示。上报成功
    仅代表系统接受了上报，不代表 OS 界面可见。
  - 系统音频回调不再内联执行引擎/会话工作：音频桥事件经投递顺序 FIFO 在主
    actor 上应用并以 epoch 防陈旧；语音会话在真正开始通话音频时配置，不在
    推送上报路径上重新配置。
- 测试：新增/扩展系统上报状态、去重、重复推送、上报进行中主叫号、非内联
  投递与快速激活/去激活一致性用例；受影响音频/路由/来电回归全绿。
- 发布：`v0.3.34` 预发布包含两个未签名 IPA（Feather 纯原生、AppStore PWA）与
  `SHA256SUMS`；Feather 源只指向纯原生 IPA；私有签名原生 IPA 仅交付
  Documents 与 iCloud（latest-only，0.3.33-40 转入本地 rollback）。
- 诚实边界：真机系统来电界面（锁屏/后台）与通话音频仍由用户真机验收；本版本
  不声称已在真机证实。

## 历史版本 (0.3.11 build 18)

- 修复 0.3.10(17) 遗留的真机验收缺陷：新建短信“收件人”此前是纯数字
  `.phonePad` 键盘（`TextField("输入号码")`），联系人名/中文联想实际不可达——
  匹配器单测通过但 UI 无法输入文字。现在收件人使用系统多语言键盘
  （中文/拼音/字母/数字均可输入）和“姓名或号码”占位（已本地化 en
  "Name or number" / zh-Hant "姓名或號碼"）；保留系统长按粘贴，无独立
  剪贴板行；不预选联系人、不自动发送。拨号键盘仍为纯数字自定义键盘，
  不引入系统键盘。
- 离线演示/UI 测试新增 `-callrelayDemoContacts` 合成联系人夹具（中文名、
  拉丁名、多号码联系人，全部 555 预留号段）：只写入内存快照，绝不查询或
  写入系统通讯录；`ContactsService.loadDemoFixture()` 仅在显式启动参数下调用。
- 回归：新增 `RecipientAutocompleteUITests` 4 项（iPhone 与 iPad 均通过）：
  收件人键盘字母键可达且输入的字母进入字段、拉丁名联想点按填入号码、号码
  片段跨格式命中中文名、多号码联系人展开后仅显式选择才填号、仅填收件人
  不触发发送（发送按钮保持禁用）。新增 demo 夹具单元测试；完整 521 单元 +
  既有短信 UI 流程（MessagesUITests、compose 视觉 fixture）通过。实际
  iPhone/iPad 模拟器截图证据在 `evidence/h28k/build18-autocomplete/screenshots/`。
- 发布：`v0.3.11` 预发布包含两个未签名 IPA（Feather 纯原生、AppStore PWA）
  与 `SHA256SUMS`；Feather 源只指向纯原生 IPA；私有签名原生 IPA 仅交付
  iCloud Drive 根目录（保留 0.3.10-17 与 0.3.9-16 签名包作回滚）。
- 诚实边界：真机通话音频、真实短信收发与推送仍由用户真机验收，本版本不声称
  已通过。

## 历史版本 (0.3.10 build 17)

- 修复 0.3.9(16) 真机反馈：**系统接听无声（双向）**：CallKit 激活的音频会话在
  引擎启动前归一化（仅 category/options，不触碰激活所有权）；20ms 音频节拍迁离
  主队列（主线程 600ms 卡顿不再饿死双向音频）；接收/发送网络循环脱离主执行器；
  播放调度器由串行队列独占（渲染线程回调只做轻量入队，绝不持锁转换或外呼）；
  有界“死引擎”看门狗按补全进度检测（首次采样建立基线），代际围栏 + 单 run 单次
  + 进程级 3 次/10 分钟预算，唯一受支持的恢复开关才会双向切换引擎语音处理。
  外发帧门精确一次投递（停车消费者直收、关闭即解绑、重绑按 epoch 失效）。
- **短信真实性与方向**：网关收件引擎按 PDU 首字节 TP-MTI 识别存储的
  SMS-SUBMIT（0x01 回显）与状态报告（0x02），绝不伪造入站；dry-run 发送只报
  “已提交”不报“已发送”；现场关闭短信 dry-run（先备份、无活跃通话），并对存量
  误录做可追溯纠正（sqlite 备份 + audit_log + 逐行证据导出，不可判定的保留不动）。
- **每会话线路（双卡风格）**：会话详情“对话线路”与新建短信“发件人”行（标签+号码+
  勾选）；发件箱条目只捕获一次线路，重试绝不静默换卡；无原始线路的历史记录明确
  失败；应用重启恢复的发件箱隔离（永不自动发送，仅显式重试）；短信测试模式只是
  警告不是阻断。
- **回铃音/忙音**：去电等待播放 450Hz 回铃音（1s 响/4s 停），仅填充真实下行
  ≥900ms 的静默（真实早期媒体永远优先）；忙线类结束（BUSY/REJECTED，绝不包括
  NO ANSWER/NO CARRIER/失败）播放 0.35s 交替忙音，2.8s 硬上限；忙音结束后媒体
  会话保留 1.2s（脱离路由、幂等关闭）保证可听；激活/结束/切换/新呼叫立即止音；
  不伪造任何响铃/接通状态。
- **联系人联想**：短信收件人与拨号键盘共用联想（名称大小写/变音/宽度不敏感 +
  号码数字片段；一位联系人一行，多号联系人选号展开、绝不静默选错；号码精确匹配
  自动收起；历史去重；标签本地化）。拨号联想不打断自定义键盘。
- **独立网页客户端（PWA）**：浏览器无需原生 App 即可拨打/接听/收发短信并选线路；
  绑定码分作用域（push 仅通知 / client 完整客户端，历史会话默认 push 永不自动
  升级）；client 会话为 HttpOnly+Secure+SameSite=Strict Cookie（滑动 TTL、可吊销、
  页面 JS 永不持有可用令牌）；服务端完整源站校验（方案+主机+端口，含可信代理
  方案与全部浏览器 WS 升级）；无 App 时可用控制台配对密钥自助注册（浏览器 Ed25519，
  注册后设备令牌立即丢弃）；通知点击直达网页接听（前台+手势申请麦克风）。
  pcma.js 与 Go 编解码逐字节一致（node 校验并接入 go test）。
- 视觉：对话页按系统短信外观（单一头像+名称 pill、隐藏主 Tab、气泡分组、状态在
  自己气泡下方、紧凑 收件人/发件人 行、无剪贴板按钮、iPad 居中会话列、Apple 短信绿
  外发气泡），截图证据 evidence/h28k/build17-repair/screenshots/。
- 测试：原生 520 单元 + 15 UI（iPhone）+ MessagesVisualReview 8（iPhone/iPad
  各 4）通过；网关 go test ./... 绿（含 6 项独立客户端授权验收 + PCMU 一致性）；
  现场 H28K 部署并验证（哈希/健康/会话作用域迁移）。

## 历史版本 (0.3.9 build 16)

- App Store 版的可选 Bark 通知桥整体替换为**自托管 PWA Web Push**：每个网关在
  自己已有的 HTTPS 域名上托管可安装 PWA（iOS 16.4+ 添加到主屏幕），自持 VAPID
  密钥、自己发送标准 Web Push；无中央服务、无第三方 Bark 依赖。App 侧只保留
  绑定码生成与通知方式选择，浏览器绑定/订阅/测试都在网关自己的网页里完成。
- 安全：绑定码短时单次、握手后由网关签发派生网页会话（与原生抽凭据隔离）；
  浏览器订阅密钥只存网关、任何视图不回传；handoff 令牌放在网址片段、兑换走
  POST 请求体（URL 路径与查询不进任何访问日志）；端点 SSRF 防护（仅公网 HTTPS +
  特殊用途地址段拒绝 + DNS 重绑定失败关闭 + 禁止跟随重定向）；解除配对/删除
  设备同时清除浏览器订阅与会话。
- 通知方式默认仅系统推送；选“仅网页推送”需要先绑定浏览器（否则保存被拒绝），
  退订最后一个订阅会自动回落系统推送，不会静默丢失通知路径。
- 测试：原生 486 单元 + 15 UI 通过；PWA 505 单元通过；网关 `go test ./...` 绿
  （订阅/令牌/SSRF/去重/撤销/模式守卫/handoff POST/精确来电收窄全覆盖）+ 本地
  smoke 全流程与无头浏览器逐步断言（含二次通知同页刷新）。证据见
  `evidence/h28k/pwa-notifications/`。
- 来电定位：handoff 返回的 callId+gatewayId 作为**不可信提示**传入
  `callrelay://incoming?call=<id>&g=<gw>`；App 用已配对凭据重新校验授权响铃
  集合后才收窄展示，提示过期/外来时回退全量检查，多通并发永不选错来电。
  已打开通话页时第二次通知经 hashchange / SW message 带代际重启流程，不残留旧来电。
- 诚实边界：真机 iPhone 的 Safari 网页推送送达与通知单次点击行为（声明式
  navigate 与 scheme 自动跳转）尚未真机验证；自动跳转是尽力而为，被拦截时
  页面内提供显式「在 CallRelay 中打开」按钮——单次点击直达原生在真机实测前
  不作声明。

## 历史版本 (0.3.8 build 15)

- 配合网关音频修复（H28K `callrelay-worker`：ALSA 采集周期 128 ms → 20 ms 语音帧，
  消除下行 6–7 帧突发导致的持续丢帧与静音，实测修复前管道读间隔中位数 0.01 ms +
  128 ms 空洞、修复后中位数 20.0 ms）：修复 0.3.7(14) 真机反馈的直连与中继通话
  声音断续、中继几乎无声。
- App：解除配对不再清除设备级 VoIP 令牌（修复重新配对后后台来电可能一直不响、
  需重启应用才恢复的路径）；诊断新增双向音频电平聚合、节拍间隔证据、PushKit
  接收→决定→上报生命周期日志（详见 `evidence/h28k/build15-repair/app-diagnostics.md`）。
- 测试：原生 486 单元 + 15 UI 通过；Bark 504 单元通过；网关 `go test ./...` 绿
  （含确定性突发/匀速对比回归）。本地证据见工作区 `evidence/h28k/build15-repair/`。
- 发布：`v0.3.8` 预发布包含两个未签名 IPA 与 `SHA256SUMS`；私有签名原生 IPA
  仅交付 iCloud Drive 根目录（保留 0.3.7-14 签名包作回滚）。
- 已知物理关卡（诚实边界）："通话安静"投诉的方向性根因依赖新电平计数器在真机
  复测后确认；后台来电系统级响铃的根因尚未观测确认（本版本提供贯通判定日志，
  不声称已修复）；构建 15 的真机通话与锁屏验收由用户完成。

## 历史版本 (0.3.7 build 14)

- 修复 0.3.6(13) 真机反馈：CallKit 音频激活转发到全部媒体会话（中继通话不再无声）、
  路由切换可取消且有界（不再卡死/被旧候选覆盖）、设置→关于→诊断新增有界脱敏日志与
  一键导出（两版本均含）。
- 测试：原生 480 单元 + 15 UI 通过；Bark 498 单元 + 15 UI 通过；两个 `Release` 变体
  无签名真机配置编译通过；CI run `37132684112`（commit `5948948`）全绿。
  本地证据见工作区 `evidence/h28k/build14-repair/`。
- 发布：`v0.3.7` 预发布包含两个未签名 IPA（Feather 纯原生、AppStore Bark）与
  `SHA256SUMS`；Feather 源只指向纯原生 IPA。
- 已知物理关卡（诚实边界）：构建 14 尚未在物理真机完成通话与锁屏验收，不声称真实
  通话已通过；H28K 个人网关已配置沙箱 APNs provider（生产/TestFlight 推送未配置）；
  Bark 锁屏自动化未在真机验证，保留手动点按回退。
