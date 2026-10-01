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
