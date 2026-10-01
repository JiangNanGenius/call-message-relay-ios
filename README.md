# CallRelay

一个用于自有 QDC507 蜂窝网关的原生 iPhone 客户端。SIM 留在 H28K，iPhone 通过
CallKit 与原生 WebRTC 接打网关 SIM 的电话。默认界面语言为简体中文。

首版已实现：Ed25519 一次性配对与网关身份绑定、Keychain 私钥/令牌、HTTPS REST 与
授权 WebSocket 事件、令牌轮换与幂等、拨号 / 最近通话 / 设置三个标签、来电与通话
控制、原生 WebRTC（PCMU 8kHz）音频、PushKit/CallKit 来电路径，以及完全离线的
**演示模式**。网关协议参考 [CellBridge v2.0.6](https://github.com/mccding/CellBridge/tree/v2.0.6)。

本仓库只包含独立客户端，不含模块刷机资料、固件、云端凭据或私人设备数据。

## 功能范围

- **拨号**：Phone 风格拨号盘、线路与 SIM/注册/信号状态、一通电话一条线。
- **最近通话**：按天分组的通话记录、来去电与接通结果、空状态。
- **设置**：连接状态、网关信息、解除配对（删除本机私钥与令牌）、演示模式入口。
- **配对**：粘贴或扫码网关一次性配对数据；Ed25519 私钥留在 iPhone
  （Keychain `afterFirstUnlockThisDeviceOnly`），先匿名校验网关 id/公钥指纹再发证明。
- **通话**：CallKit 系统通话界面，拨出/接听/拒绝/挂断/静音/DTMF/扬声器；真实“已接通”
  需要网关 `active` 且媒体连通，REST 201 不会显示已接通。
- **音频**：stasel/WebRTC M151，非 trickle ICE，与上游一致的 **PCMU/8kHz**，开启
  WebRTC 回声消除/降噪/自动增益，音频会话遵循 CallKit 所有权。
- **推送**：PushKit VoIP + 普通 APNs 令牌注册；非 UUID 的网关呼叫 id 用确定性
  UUIDv5 稳定映射，推送/事件/轮询收敛到同一通系统通话。
- **演示模式**：内存假网关，保留的 555 模拟号码，绝不联网、发短信或触发真实来电。

## 快速开始

需要 Xcode（部署目标 iOS 17+）、XcodeGen。首次：

```sh
./Scripts/bootstrap.sh     # 下载并校验固定校验和的 WebRTC M151
xcodegen generate         # 生成 CallRelay.xcodeproj
```

构建、测试、无签名真机编译、签名与 APNs 说明见 [BUILD.md](BUILD.md)。
协议事实、安全设计与“已验证/未验证”边界见 [PROTOCOL.md](PROTOCOL.md)。

## Feather 安装源

在 Feather「源」中添加：

```
https://raw.githubusercontent.com/JiangNanGenius/call-message-relay-ios/main/feather.json
```

源提供首版预览的**未签名 IPA**，由 Feather 使用你自己的证书与描述文件签名后安装。
无需上架 App Store。下载地址、版本、大小与 SHA-256 取自 GitHub Release 的实际产物。
后台 VoIP 来电仍需匹配 Bundle ID、Push Notifications 描述文件和自有 APNs 服务；
重新签名安装成功不代表后台推送或真实网关通话已经验收。

## 音质边界（重要）

当前**网关实现**（CellBridge v2.0.6 的 UAC + WebRTC）固定 **8kHz / PCMU 64kbps
窄带**，即传统电话音质，**不是 HD/宽带**。QDC507 硬件或刷机后固件是否支持 16kHz
宽带 / 运营商 AMR-WB 尚未验证；若将来实测支持，需要网关与 App 整条链路升级编码协商，
首版不扩展宽带编码，也不对延迟或 DSP 效果做无依据承诺。

真机仍需逐项验收：双向可听、回声/降噪、听筒/扬声器/蓝牙路由、音频中断恢复，以及
Wi‑Fi/蜂窝切换和弱网（含 TURN 中继）。

## 尚未验证的关卡

- 真实 H28K/QDC507 的 AT/UAC 与双向音频、私有 TURN/coturn 中继。
- 自有云受限控制通道与 APNs Push Broker；真机锁屏 VoIP 来电（sandbox/production）。
- 物理 iPhone 的签名、描述文件与后台 VoIP 行为。模拟器与测试目标已编译通过，测试执行结果以本仓库 CI 为准；
  但 CallKit/PushKit/真实音频必须在签名真机与真实网关上验收。

## 使用范围与许可证

本项目源码公开，采用 **PolyForm Noncommercial 1.0.0**，仅授权非商业用途；完整条款见
[LICENSE](LICENSE)。第三方组件（Google WebRTC 等）沿用
各自许可证，见 [ThirdPartyNotices.md](ThirdPartyNotices.md)；接口参考不代表复制或
重新授权上游代码。

项目用于自行构建与安装，不计划上架 App Store。
