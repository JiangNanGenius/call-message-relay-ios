# 协议与证据边界

本客户端针对固定参考 **CellBridge v2.0.6**
（提交 `2ee9d6b05d8a4391f782e6ce8a6d23ef57015fda`）实现。下列约定来自直接阅读
网关 Go 处理器与模型，而非只看 OpenAPI 文本。

## 已核验的线缆事实

- 基址 `https://{gateway}/api/v1`；业务请求使用 `Authorization: Bearer <accessToken>`。
- 时间单位：
  - 配对 `pairing/start.expiresAt` 为 Unix **秒**（`auth.PairingStart` 用 `Unix()`）。
  - 通话、消息、事件 `createdAt`、录音时间为 Unix **毫秒**（`UnixMilli()`）。
  - `calls/{id}/ice` 的 `expiresAt` 为 **RFC3339 字符串**，可能不含小数秒。
- 字段大小写：通话与消息响应为 `gatewayID` / `lineID`（大写 ID），其余为 camelCase。
- `/calls` 列表恒为 JSON 数组（空时是 `[]`，不是 `null`）。
- 变更类请求要求 `Idempotency-Key` 头（网关要求非空、≤200 字符；OpenAPI 标注 uuid）。
- `/auth/refresh` 请求 `{refreshToken}`，响应**只含** `accessToken` 与
  `refreshToken`（无 deviceId）；网关轮换并吊销旧 refresh token，客户端保留原 deviceId。
- `/devices/{deviceId}/push` 方法为 **PUT**，且路径里的 deviceId 必须等于令牌所属设备。
- 配对：
  - `pairing/start` 仅本地（loopback/私网/Tailnet），返回一次性密钥与网关公钥指纹。
  - 一次性签名证明消息精确为
    `pairingId + "\n" + oneTimeSecret + "\n" + gatewayId + "\n" + deviceName`，
    Ed25519 签名；公钥与证明以 base64（RawStd/Std 网关都接受）上送。
  - 配对成功返回 `{deviceId, accessToken, refreshToken}`。
- 通话状态：`idle / incoming_ringing / outgoing_dialing / connecting / active /
  ending / recovering`。逻辑呼叫 id 取自拨出时的 `clientCallId`，因此可能不是 UUID；
  来电与历史 id 也是字符串。
- WebRTC：
  - 网关只注册 **PCMU（G.711 µ-law）/8000，单声道，payload type 0**。
  - 非 trickle：客户端等待 ICE 收集完成后在一次性 offer 中带上候选；网关在
    `CreateAnswer` 内等待收集完成再回 answer。
  - tailnet/remote 为 relay-only ICE；TURN 短期凭据来自 `/calls/{id}/ice`。
  - 只有网关对端状态 `active`（cellular+media 都就绪）才是真正接通。
- 事件：WebSocket `/api/v1/events`（bearer），信封 `{id, seq, type, createdAt, data}`；
  `type` 含 `line.updated / call.incoming / call.updated / call.ended / ...`；
  服务端约 25 秒发一次 WebSocket ping。
- VoIP 推送信封：`{callUUID, callId, handle, gatewayId, issuedAt}`（issuedAt 为秒）。
  上游发送端当前把 `current.ID` 同时放进 `callUUID` 与 `callId`，**不保证是合法 UUID**。

## 安全实现

- 端点校验：默认强制 HTTPS；仅在显式调试开关下允许 `localhost/127.0.0.1/::1` 的 HTTP；
  拒绝非 http(s) scheme、URL userinfo、fragment。无全局 ATS 例外。
- 重定向：仅允许同主机/同端口/同协议跟随，跨源或降级到 HTTP 时取消，避免 Bearer 泄露。
- 身份绑定：配对前与每次建立凭据连接前，先用**匿名** `/identity` 比对 gatewayId 与
  公钥指纹；不匹配则阻断所有带令牌的 REST/WS 路径并提示重新配对。
- 私钥：设备 Ed25519（CryptoKit `Curve25519.Signing`）原始密钥存 Keychain，
  `afterFirstUnlockThisDeviceOnly`。Ed25519 不能进 Secure Enclave，故不做该声明。
- Token：access/refresh 存 Keychain；401 时串行化、只刷新一次再重试原请求；不盲目重试
  计费/变更命令；事件流是只读流，断线按指数退避+抖动重连。
- 日志：只记录操作类别、状态码与安全错误码，不写号码、SDP、token、密钥、完整呼叫 id
  或路径；关联使用不可逆短哈希。

## CallKit / PushKit

- 用确定性 UUIDv5 把任意网关呼叫 id 映射到 CallKit UUID；已是 UUID 时原样使用。
  推送、事件、REST 轮询与重放因此收敛到同一个系统通话，避免重复来电。
- VoIP 推送在 await 报告 CallKit **之前**先占位去重；`mustReport` 为真但负载损坏/异网关/
  过期时，报告一个立即结束的最小占位通话以满足 PushKit 合规，且在报告+结束后才调用
  completion。绝不把占位伪造成真实通话。
- 接听：CXAnswerCallAction 的 fulfill/fail 只取决于网关 `/answer` 是否接受；媒体在其后
  异步建立，避免等待 `didActivate` 形成环形等待；媒体失败会结束网关通话与系统通话。
- 代次（generation）保护：挂断/重置/切换模式会令在途 dial/offer/answer 的迟到结果失效；
  若取消时网关可能已建立通话，则用同一呼叫做补偿性 hangup；provider reset 也尽力收敛网关。
- 真实“已接通”要求网关 `active` 且 WebRTC 连接建立；REST 201 不会显示已接通。

## 音频质量边界（当前实现，不是硬件永久上限）

- 当前 **网关实现** 经 UAC + WebRTC 固定为 **8kHz / PCMU 64 kbps 窄带**，不标注 HD/宽带。
- QDC507 硬件或刷机后固件是否支持 16kHz 宽带 / 运营商 AMR-WB **尚未验证**；若将来实测
  支持，需要网关与 App 整链升级编码协商，首版不扩展宽带编码。
- App 侧开启/请求 WebRTC 音频处理：回声消除、降噪、自动增益、高通滤波；音频会话遵循
  CallKit 所有权（voiceChat 模式，听筒/扬声器/蓝牙路由由系统管理），扬声器切换只做
  output-port override，不自行抢占激活。
- UI 仅显示真实可测的粗粒度连接质量（连接状态、可选 RTT/丢包统计），不做无依据的
  DSP/延迟承诺。

## 尚未验证的真实关卡

- 真实 H28K/QDC507 上：AT 控制、UAC 枚举、PCM 非零、双向可听、回声/蓝牙/扬声器、
  音频中断与 Wi‑Fi/蜂窝切换。
- 私有 TURN/coturn 中继在弱网与 UDP 受限时的连通（含 TURN/TLS 443 备选）。
- APNs：自有 Push Broker、真机 VoIP 锁屏唤醒、sandbox/production 环境一致性。
- 自有云 FRP 受限控制通道与事件重放/补同步在发布成品上的实际行为。
