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

## 短信（SMS）线缆事实

直接核对 `server.go` 的 `messageResponse`/`threadResponse`、`messages`/`messageAction`
处理器与 `internal/sms/engine.go`：

- `GET /messages?after&limit`：`after` 为 `sync_seq` 游标，返回**时间升序**的裸 JSON 数组
  （空为 `[]`）；`limit` 1–500。
- `GET /messages?threadKey=&before=&beforeId=&limit=`：单对话最新一页，服务端先按
  `created_at DESC, id DESC` 取 `limit+1` 判定再翻回**时间升序**；是否还有更早的消息通过
  响应头 **`X-CellBridge-Has-More: true|false`** 给出；`beforeId` 必须与 `before` 同时出现。
- `POST /messages`：请求体 `{to, body}`（to 去空白后 1–32 字符；body 非空、≤10000 rune）；
  必须带 `Idempotency-Key`。成功 **201** 返回 `messageResponse`；调制解调器在消息落库后
  拒绝 PDU 时返回 **502 且体里仍是 `messageResponse`（status=failed）**——客户端把它作为
  真实失败消息展示，而不是仅当错误丢弃。
- 消息字段：`id, gatewayID, lineID, threadKey, direction(inbound|outbound), peer, body,
  encoding(gsm7|ucs2), status, createdAt(Unix 毫秒)`。
- 状态：引擎实际写入 `queued → submitted → sent`，失败写 `failed`；入站消息入库时为
  `sent`；`POST /messages/{id}/read` 成功 **204**，此后入站消息状态为 `read`。
  `delivered` 仅在枚举/OpenAPI 中预留，首版不声称已送达。
- `GET /threads`：裸数组，元素 `{key, peer, unreadCount, lastMessage: Message}`；
  `unreadCount` 只统计未 `read` 的入站消息。
- 事件：入站/发送完成时发布 `message.created`，`data` 即 messageResponse；协议枚举还保留
  `message.updated`，客户端两者都按消息对象合并。
- 短信发送门槛来自 `/line`：`sim=ready` 且 `registration=registered` 且 **`sms=ready`**
  （AT 适配器在正常轮询时上报短信 ready；不能只看 `voice`）。
- 客户端幂等策略：同一逻辑提交（含网络失败后的重试）固定使用一个 Idempotency-Key，网关
  会重放已完成的同一响应，因此重试不会产生第二条短信；对已落库 `failed` 的消息改用
  **新**幂等键重新提交（旧键只会重放失败结果）。
- 快照对账：断线重连或回前台时，客户端只做**一次**有界的 `GET /messages?after=0&limit=200`
  补水（`after` 是 `sync_seq`，而 messageResponse 不回传该序列，因此不做光标语义翻页），
  按消息 `id` 幂等合并后刷新 `/threads`；打开具体对话时再按 thread 分页取更早历史。
- `/sync`：`SyncResponse{from,to,hasMore,changes[]}`，`changes[]` 仅含
  `{seq,entity_type,entity_id,op}`（不含实体正文），用于知道“有变更”而非直接取数。

## 本地过滤、通讯录与云同步（非网关协议）

- 垃圾规则、名单、信任号码、待发短信全部只存本机：规则为 JSON 文件，待发短信以
  网关标识哈希做作用域、受数据保护的 outbox 文件；两者都不含凭据，名单 HTTPS 拉取不带
  任何鉴权头、不上传统计。
- 联系人经系统 `CNContactStore` 读取（统一联系人天然包含系统 iCloud 联系人），导出使用
  `CNContactVCardSerialization`，全程不修改系统通讯录。
- 可选 iCloud 同步使用 CloudKit **私人数据库**自定义 zone，正文/号码/姓名与规则/名单
  设置的 JSON 全部写入 `CKRecord.encryptedValues`（CloudKit 服务端加密存储，属于加密
  at-rest；并非在所有账号设置下都保证端到端加密），记录名为 `entity|logicalID`（首个
  `|` 分隔，逻辑 id 可含 `.`；逻辑 id 带 `<scope>.` 前缀，不同网关相同原始 id 不冲突），
  按网关标识 SHA-256 前缀做 scope 隔离；删除始终复制为独立的**墓碑记录**
  （`SyncTombstone|entity|logicalID`，实体感知、可复制、按 deletedAt LWW），物理删除仅
  为尽力清理且不作为 ACK 依据；同步每轮**先拉后推**，按归档记录的 change tag 做乐观
  保存（`.ifServerRecordUnchanged`），冲突返回 serverRecordChanged 由纯函数收敛，增量
  token 过期自动全量重拉并重置基线。基线不声明 CloudKit 能力，启用前先解析
  embedded.mobileprovision（精确匹配配置容器且声明 CloudKit 服务），再在 ObjC
  `@try/@catch` 保护下用 `CKContainer.accountStatus`/`fetchUserRecordID` 实测生效签名
  权限和账号身份（描述文件权限可能宽于实际签名权限；不用 iCloud Drive 的
  ubiquityIdentityToken 判断 CloudKit 登录），未配置时只显示不可用、不触碰 CloudKit。


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

- 真实网关短信：收件、中文与长短信、发送失败重试、未读/已读同步。

- 真实 H28K/QDC507 上：AT 控制、UAC 枚举、PCM 非零、双向可听、回声/蓝牙/扬声器、
  音频中断与 Wi‑Fi/蜂窝切换。
- 私有 TURN/coturn 中继在弱网与 UDP 受限时的连通（含 TURN/TLS 443 备选）。
- APNs：自有 Push Broker、真机 VoIP 锁屏唤醒、sandbox/production 环境一致性。
- 自有云 FRP 受限控制通道与事件重放/补同步在发布成品上的实际行为。
