# CallRelay

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

Swift / SwiftUI, CallKit, PushKit, CryptoKit, Keychain, URLSession and native WebRTC. This implements the native iPhone plan authorized in the conversation. Build an Xcode project from XcodeGen; iOS 17 or later. No App Store submission.

## Users

The owner of a HINLINK H28K and DJI IG830/QDC507 modules, using their own SIM from their iPhone while the module remains attached to the gateway.

## Product Purpose

Pair the iPhone with the owned cellular gateway, send and receive gateway SIM SMS and make/receive gateway SIM calls through the iPhone system experience, and inspect messages, connection and call history.

## Operating Context

H28K hardware preparation is a separate concurrent task. This repository is an independent iPhone client. CellBridge v2.0.6 is the gateway protocol reference. A self-hosted cloud relay, TURN and APNs broker will be integrated later. Development must work without touching the hardware.

## Capabilities and Constraints

- One gateway line and one active call initially.
- First release includes basic SMS: conversation list by number, conversation view, compose with pasteable recipient and multiline body, truthful queued/submitted/sent/failed status with idempotent retry, polling and event refresh, plus offline demo messages. No fabricated delivery state; sending requires SIM ready, registered network and gateway SMS capability.
- Private key stays on the iPhone; pairing exchanges public keys and verifies a one-time challenge. Gateway tokens stay in Keychain.
- CallKit manages system calls; WebRTC carries audio. Gateway state and media readiness govern call state.
- Real foreground calling code is required; no fake connected/ready states outside explicit isolated demo mode.
- PushKit requires the owner's Apple signing/APNs setup; no App Store listing is planned.
- Public GitHub repository with PolyForm Noncommercial 1.0.0; commercial use is not granted. Dependencies retain their own licenses.
- Never publish host-specific credentials, phone/SIM identifiers, modem backups or preparation files.

## Evidence on Hand

The pinned gateway protocol is available as a read-only reference in the adjacent workspace preparation directory. There is no real call acceptance yet. Only explicit synthetic demo records may appear in UI development.

## Product Principles

- Make calling and connection failures understandable.
- Preserve system call and audio behavior.
- Keep unpaired, offline, unsupported and ready states distinct.
- Preserve the owner's private keys and bound gateway identity.

## Undecided

CallRelay is a working name chosen for this first implementation. Domain, signing team, final Bundle ID and cloud deployment are not yet provided. Default interface language is Simplified Chinese based on the owner's communication; follow system appearance and accessibility settings.

## 统一网关 (v2) 增量

- 一次扫码/粘贴配对即可获得该密钥授权的全部线路；每台手机独立注册、独立撤销。
- 短信与通话历史带线路标签，可筛选；外呼与发送默认使用所选线路，线路不可用时要求重新选择，不会静默改号。
- 支持保持/恢复、第二通来电保持后接听、把本机接听的 2-3 路外呼合并为最多 4 人会议；会议中可单独保持/移除/对选中线路发 DTMF。
- 无人接听或设备确实不可达时，网关播放问候语与提示音后录制语音留言；留言按线路接听权限隔离，可在 App 内播放。
- 跨设备恢复只同步加密恢复授权，设备私钥与访问令牌始终只留本机；撤销的设备不会自动重新注册。
