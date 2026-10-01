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
（大小写/秒与毫秒/RFC3339/裸数组）、端点与重定向安全、callId→UUID 稳定映射与
VoIP 推送去重策略、PCMU-only SDP 过滤、通话阶段判定，以及带可控延迟 Fake API 的
取消/迟到响应/媒体失败/远端挂断竞态。

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

## 演示模式

未配对时可进入「演示模式」：完全离线的内存网关，使用保留的 555 模拟号码，不联网、
不发短信、不触发真实系统 CallKit 来电，仅用于走查界面与状态切换。设置页可模拟来电。
