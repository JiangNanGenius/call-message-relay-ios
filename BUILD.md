# 构建与运行

CallRelay 是原生 iOS 17+ App，使用 XcodeGen 生成工程，依赖一个固定校验和的
WebRTC M151 二进制包。本仓库不提交 `.xcodeproj` 之外的大型二进制；首次构建前先运行
bootstrap 脚本。

## 环境

- Xcode 26.4+（部署目标 iOS 17；CI 固定 Xcode 26.6，本地编译使用 Xcode 27 beta）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（已验证 2.46.0）
- 命令行使用 `xcode-select` 当前指向 Command Line Tools 时，请为每条命令设置
  `DEVELOPER_DIR`，**不要**改动全局 `xcode-select`：

  ```sh
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
  ```

## 1. 拉取并校验 WebRTC

```sh
./Scripts/bootstrap.sh
```

脚本从 GitHub release 下载 `WebRTC-M151.xcframework.zip`，比对固定 SHA-256
（也是 SPM 校验和）：

```
6f3f5693383ce65763190c46ca9f2c4325c34b83681acb9db30f01488e15f1e0
```

校验通过后解压到 `Vendor/WebRTC/WebRTC.xcframework`（已被 `.gitignore` 忽略）。

> 说明：上游 stasel/WebRTC 的 Swift 包 **tag** `151.0.0` 指向的 release 资产当前
> 返回 404；字节相同的 M151 二进制以相同文件名、相同校验和重新发布在 release tag
> `151.0.1`。为继续使用**确切的 M151**而非静默升级，本项目用本地包按校验和固定该
> 二进制。详见 `ThirdPartyNotices.md`。

## 2. 生成工程

```sh
xcodegen generate
```

产出 `CallRelay.xcodeproj`。Bundle ID 占位为 `com.jiangnangenius.callrelay`，
**未**填写 `DEVELOPMENT_TEAM`，默认按无签名构建配置。

## 3. 模拟器构建（无签名）

不依赖特定设备、也不需要先启动模拟器（适合 CI/无头校验）的通用模拟器目标：

```sh
xcodebuild build \
  -project CallRelay.xcodeproj -scheme CallRelay \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

针对具体模拟器（运行测试时使用）：

```sh
xcodebuild build \
  -project CallRelay.xcodeproj -scheme CallRelay \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

用 `xcrun simctl list devices available` 获取本机的 `<SIMULATOR_UDID>`。
测试前可用 `xcrun simctl boot <SIMULATOR_UDID>` 和
`xcrun simctl bootstatus <SIMULATOR_UDID> -b` 等待启动。
本地 iOS 27 beta 运行环境曾在启动阶段超时，因此编译通过与测试执行通过分别记录，
不将模拟器启动失败算作测试通过；CI 使用稳定版 Xcode 与模拟器执行测试。

## 4. 逻辑测试

仅校验测试可编译（不启动模拟器，无头可用）：

```sh
xcodebuild build-for-testing \
  -project CallRelay.xcodeproj -scheme CallRelay \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

在已启动的模拟器上执行测试：

```sh
xcodebuild test-without-building \
  -project CallRelay.xcodeproj -scheme CallRelay \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
# 或一步完成（会自行构建并在模拟器就绪后运行）：
xcodebuild test \
  -project CallRelay.xcodeproj -scheme CallRelay \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

测试覆盖：Ed25519 一次性配对证明与 Keychain、真实 handler JSON 的线缆兼容
（大小写/秒与毫秒/RFC3339/裸数组）、短信端点与字段（线程/对话/发送幂等/502 失败消息/
Has-More 响应头）、端点与重定向安全、callId→UUID 稳定映射与
VoIP 推送去重策略、PCMU-only SDP 过滤、通话阶段判定、短信收件箱（重试同键、切换模式后
迟到响应作废、已读回执、演示路径、垃圾隔离/恢复、混合对话误判、断线补水幂等合并、待发箱
重启恢复）、号码归一化（+86/0086/区号）、垃圾预设与白名单优先级、名单解析/大小上限/
精确匹配、退避重试与错误分类（429 Retry-After/5xx/4xx/授权失效）、ICE 短暂断开恢复与
超时结束、联系人去重分组（同名同事无共同号码仅警告）与 vCard 全量导出（每个联系人
恰好一次、富字段保留、重叠组不双导出、+86 归一化）、CloudKit 同步（点分逻辑 id、
飞行中再入队的新版本不被旧 ACK、并发设备 serverRecordChanged 冲突、墓碑复制失败不
ACK、账号切换清墓碑/队列/token、token 过期全量重置、规则回环抑制、网关 scope 隔离、
描述文件精确容器+CloudKit 服务解析、ObjC 异常边界、亚秒时间戳持久化）、事件流
（ping 握手 .open、401 终态、429 Retry-After、kick 取消旧定时器/旧 socket 迟到回调
不得替换新连接）、CallKit handle 类型与 Intent/tel: 入口解析，以及带可控延迟 Fake API
的取消/迟到响应/媒体失败/远端挂断竞态。

另有独立的 **CallRelayUITests**（XCUITest，UI-test target，不在单元测试 target 内），
通过 `-callrelayDemoMode -callrelayUITestReset -callrelayDemoSpamPresets` 启动参数进入
完全离线、规则隔离的演示，走查短信列表→对话→编写→发送状态→垃圾信息隔离与恢复→规则预览
→设置中的系统铃声说明，并保存 `XCTAttachment(.keepAlways)` 截图（明暗两种外观）；
需要在已启动的模拟器上运行（CI 的稳定模拟器负责执行与目视检查，本机 iOS 27 beta 不启动
模拟器）。所有演示与测试号码均为保留的 555 合成号码。

## 5. 真机无签名编译（仅编译验证，不可安装）

```sh
xcodebuild build \
  -project CallRelay.xcodeproj -scheme CallRelay \
  -configuration Release -sdk iphoneos \
  -derivedDataPath build/DerivedData-device CODE_SIGNING_ALLOWED=NO
```

CallKit/PushKit/麦克风与 VoIP 后台模式需要描述文件与签名才能在真机运行；无签名
`iphoneos` 构建只用于验证可编译性。

## 签名与 APNs（真机）

- 工程 entitlement 使用 iOS 的 `aps-environment`（注意：带
  `com.apple.developer.` 前缀的是 **macOS** 键，iOS 不要用）。
- Debug 默认 `aps-environment = development`，对应 APNs **sandbox**；发布/TestFlight
  与生产网关需改为 `production`，并在网关注册时上报匹配的 `environment`。
- 真机需要：可 VoIP 的 App ID、Push Notifications 与 Voice over IP 后台能力、
  你的开发团队与描述文件。设置团队（不要写死在仓库里）：
  ```sh
  xcodebuild ... DEVELOPMENT_TEAM=<你的TeamID> CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
  ```
- 云端 APNs Broker（用自己的 Bundle ID 与 APNs 授权）尚未实现，锁屏来电的端到端
  验证属于后续阶段。

### 可选 CloudKit 重签配置

未签名/Feather 基线**不**包含 iCloud 能力，App 内同步开关会安全显示“不可用”。
要启用同账号私人同步，需在你自己的开发者账号下完成（不要把 Team/容器写死进仓库）：

1. 在 Apple Developer 为该 App ID 勾选 iCloud → CloudKit，并创建私人容器，
   例如 `iCloud.<你的BundleID>`（容器名由你账号决定）。
2. 用包含 `com.apple.developer.icloud-services = CloudKit`、
   `com.apple.developer.icloud-container-identifiers` 与 APNs（CloudKit 远程通知）的
   描述文件重签。客户端启用前做两道检查：先解析 `embedded.mobileprovision`（必须精确
   包含配置容器且声明 CloudKit 服务），再在 ObjC `@try/@catch` 保护下调用
   `CKContainer.accountStatus` 与 `fetchUserRecordID` 实测**生效**签名权限。Feather 等
   “宽描述文件 + 可执行文件被剥权”的情况下，CKContainer 初始化会抛 ObjC NSException
   （Swift do/catch 无法捕获）；异常边界会把它转为“不可用”，绝不崩溃。登录判断不使用
   iCloud Drive 的 `ubiquityIdentityToken`（CloudKit-only 账号可能没有它）。
3. 容器标识可通过 UserDefaults `callrelay.cloudSync.containerID` 覆盖为你账号里的
   真实容器；默认值 `iCloud.com.jiangnangenius.callrelay` 仅为示例，未在任何账号注册。
4. 即使缺少容器，本地短信/通话/规则/导入名单功能全部照常可用；联系人同步由系统
   “iCloud 联系人”提供，与该 CloudKit 容器无关。
5. `CKRecord.encryptedValues` 是 CloudKit 的服务端静态加密（at rest），不要把它描述
   成在任何 iCloud 账号设置下都保证端到端加密（高级数据保护由系统设置决定）。

## 演示模式

未配对时可进入「演示模式」：完全离线的内存网关，使用保留的 555 模拟号码，不联网、
不发短信、不触发真实系统 CallKit 来电，仅用于走查界面与状态切换。设置页可模拟来电。

## Feather 发布

CI 在测试通过后编译 `iphoneos Release`，打包 `Payload/CallRelay.app`，保留内嵌 WebRTC，
将未签名 IPA 保存为 `unsigned-ipa` artifact。用自己的证书在 Feather 中重新签名。
发布者先上传带版本号的未签名 IPA 到版本固定的 GitHub Release（v0.2.1 使用
`CallRelay-0.2.1-unsigned.ipa`，另附 `SHA256SUMS`），再执行：

```sh
./Scripts/update-feather-source.py build/release-v0.2.1/CallRelay-0.2.1-unsigned.ipa --tag v0.2.1
```

生成并提交 `feather.json`，其中版本、Bundle ID、最低 iOS、文件大小与 SHA-256 均从
实际 IPA 提取，下载地址固定为
`https://github.com/JiangNanGenius/call-message-relay-ios/releases/download/v0.2.1/CallRelay-0.2.1-unsigned.ipa`。
该脚本会重建整份源（只保留当前版本）；若要在 `versions` 中保留旧版本条目与既有截图，
需在生成结果上手工补回，或直接编辑已提交的 `feather.json`。公开源不包含证书、私钥或
描述文件。
