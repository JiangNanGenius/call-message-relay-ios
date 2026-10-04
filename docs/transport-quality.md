# Call quality management — implemented vs remaining (2026-10-05, build 27)

## Build 27 headline: Opus on the WSS relay too, with framed gap detection

The WSS relay (the dominant path on cellular) now negotiates **Opus** as
well: the attach URL carries `codec=opus`, the gateway answers
`{"type":"ready","codec":"opus","fmt":"seq16"}` when it accepts, and both
sides carry **sequence-stamped 20 ms frames** (`[seq u16 BE][Opus payload]`)
instead of bare payloads. The sequence counts MEDIA SLOTS, not sent frames:
when the bounded send queue drops a stale frame (or an encode fails), the
hole stays visible on the wire, so the receiver runs mature libopus PLC for
exactly the missing slots — the stateful decoder's timeline stays aligned
instead of silently shifting by one frame. A one-slot gap recovers via
RFC 7587 inband FEC from the following packet (libopus `decode_fec`), with
PLC fallback. A build-26 gateway (bare Opus, no `fmt`) still works: the app
decodes what arrives, honestly without gap detection. A pre-26 gateway
answers PCMU and the legacy 160-byte protocol is byte-identical.

WSS congestion adaptation is **closed-loop with WSS-appropriate signals**
(TCP hides loss as delay, so loss counters would be meaningless):
- Downlink: the gateway steps its Opus bitrate (16-64 kbps, 8 kbps steps,
  800 ms cooldown, 3 s clean-window requirement) from its own socket queue
  pressure (write-blockage, bounded-queue overflows) and the app's ping
  extension (`buf` = playback-buffer frames, `gap` = worst inter-arrival
  gap ms) — the freshest end-to-end delay evidence the TCP path produces.
  FEC enables on sustained gaps (>=60 ms), disables below 30 ms.
- Uplink: the pong answers with the gateway's host-buffer depth (`buf`) and
  observed uplink gap (`ugap`); the app's `WSSBitrateController` applies the
  same bounded discipline and additionally raises `OPUS_SET_PACKET_LOSS_PERC`
  (10 %) only while FEC is enabled, so inband redundancy actually exists to
  recover from. Feedback expiry / absent stats HOLD the current value, never
  raise into the unknown.
- Pacing: the app's bounded drop-stale send gate and the gateway's bounded
  socket queue stay; no fake bitrate reduction by chunk-dropping.

Tests: gateway `TestWSDepacketizeGapMath` (wrap-aware gap/duplicate math),
`TestWSSUplinkSenderDropsConcealed` (sender drop -> PLC slot delivered, post-
gap audio aligned), `TestWSSDownlinkBlockedWriterExposesDrops` (bounded queue
+ visible holes), `TestWSSUplinkDelayBurstResumes`, `TestWSSOpusFECDrivenByLossPerc`;
app `WSSFrameCodecTests` (round-trip, PLC/FEC/duplicate/obsolete/burst caps)
and `WSSFramingIntegrationTests` (negotiated framed mode, inbound gap ->
3 playback frames, outbound seq stamping). Physical validation on a real
cellular call still pending (no agent-initiated calls).

## Build 26 headline (previously shipped)

Scope: what build 26 (0.3.19) actually ships for media quality, what is
telemetry only, and what remains. No QUIC/FRP changes are made or proposed
(user decision). The modem leg is fixed-rate G.711 to the PSTN; quality work
applies to the **network hops** (app↔gateway direct WebRTC, app↔gateway WSS
relay, gateway↔worker LAN).

## 0. Build 26 headline: Opus + closed-loop adaptation on the direct path

The network hop of the **direct WebRTC path** now negotiates **Opus (RFC
7587)** — reference libopus 1.5.2 (BSD-3-Clause, statically vendored under
`gateway/third_party/opus`, reproducible build in `tools/build-libopus.sh`)
— with **PCMU as the wire-compatible fallback** (old app builds force
PCMU-only offers; a new app against an old gateway gets PCMU from the same
offer). Negotiation is offer-driven: the gateway picks Opus exactly when the
client offers it, so no version handshake exists or is needed.

| Path (build 26+) | Codec | Loss handling | Congestion response |
|---|---|---|---|
| WSS relay (cellular fallback) | **Opus 16-64 kbps NB, framed seq16** (build 27; PCMU fallback) | frame-sequence gap detection → per-slot libopus PLC + inband FEC for one-slot gaps | queue-pressure + app-reported buffer/gap (downlink) and pong-reported host buffer/uplink gap (uplink) → bounded bitrate/FEC CTLs |
| Direct WebRTC (LAN/preferred) | **Opus 16-64 kbps NB** (PCMU fallback) | **inband FEC** (loss-driven) + NACK retransmission + bounded playout deadline, encoded jitter stage (reorder/duplicate/late rejected pre-decode) | **closed loop**: GCC bitrate estimate → Opus bitrate CTL; RR loss → packet-loss-perc CTL; uplink NACK requests token-budgeted |

### What "closed loop" means here (honest boundaries)

- Downlink (gateway→phone): pion `pkg/gcc` **SendSideBWE** consumes the
  TransportLayerCC reports the phone's SDK emits (the gateway stamps every
  outbound packet with the negotiated TWCC sequence number via
  `twccExtWriter`; without it the feedback adapter cannot attribute
  departures). The estimate drives `OPUS_SET_BITRATE` inside 16-64 kbps with
  both-threshold hysteresis (≥4 kbps AND ≥15%) and an 800 ms cooldown.
- Downlink loss: Receiver Reports (fraction lost as measured by the phone)
  drive `OPUS_SET_PACKET_LOSS_PERC` (0-30, ±2 hysteresis) and the FEC
  on/off hysteresis (on ≥3 %, off ≤1 %, 5 s cooldown). `useinbandfec=1` is
  advertised in SDP.
- Feedback expiry is a **hold, never a raise**: silent TWCC/RR means unknown
  congestion; the encoder keeps its last values (raising a starved bitrate
  because feedback disappeared could worsen severe congestion). TWCC and RR
  freshness are tracked separately so a healthy RR stream cannot keep a dead
  BWE alive.
- Uplink (phone→gateway): the gateway's TWCC sender interceptor gives the
  phone transport-cc feedback for its own sending side (the Google SDK runs
  its sender-side estimator automatically once feedback arrives). The
  gateway's NACK **requests** are capped by a token bucket (12/s, burst 12)
  that is **direction-local** — no downlink estimate asserts anything about
  the asymmetric uplink.
- Pacing: audio is emitted strictly at the 20 ms mixer tick (self-paced).
  gcc's leaky-bucket pacer is deliberately replaced with the NoOp pacer: at
  16-64 kbps its per-tick budget is smaller than one audio packet, so it
  would queue packets without bound (seconds of added latency).
- PCMU sessions have **no** bitrate controller — the fixed-rate codec has
  nothing to adapt. Telemetry-only claims for PCMU would be branding.

### Tests (synthetic, real code paths — not physical proof)

- `internal/opus`: round-trip energy conservation, PLC frame fill on loss,
  CTL bounds, DTX frame size (libopus 1.5.2 on the test host).
- `internal/unified/media`: Opus offer negotiates Opus (PT 111, RFC 7587
  960-tick cadence verified on the wire); a 440 Hz tone survives
  client-encode → gateway-decode → leg PCM and gateway-encode →
  client-decode (zero-crossing rate preserved); PCMU-only offer still gets a
  PCMU answer with G.711 media (fallback locked).
- Closed-loop component test: real `gcc.SendSideBWE` + real libopus encoder
  + a real pion `twcc.Recorder` generating genuine TransportLayerCC
  feedback through the chain — the controller timestamps TWCC arrival and
  the estimator consumes the feedback.
- Controller unit tests: clamp to 16-64 kbps, both-threshold hysteresis,
  cooldown gating, loss-perc hysteresis, FEC no-flap deadband, stale-hold
  never raising, no apply-after-close, NACK budget burst/refill/filtering.

Physical validation of adaptation under real loss still requires a field
call; the components above are the real maintained implementations (pion
gcc/interceptor, reference libopus), not copies of algorithm names.

## 1. The two network paths, honestly differentiated (build 25 baseline)

| Path | Codec | Loss handling (build 25) | Latency control |
|---|---|---|---|
| WSS relay (cellular fallback) | PCMU 20 ms frames over TCP | none (TCP retransmit hides loss as delay) | app-side adaptive bounded jitter buffer (below) |
| Direct WebRTC (LAN/preferred) | PCMU RTP | **NACK retransmission both directions** + bounded playout deadline | gateway host jitter buffer (target 120 ms, timestamp-aware) + app adaptive buffer |

## 2. Implemented in build 25 (still present in 26)

### App (iOS)
- **Adaptive bounded jitter buffer** (`WSPlaybackScheduler`): the playback
  target follows the measured inter-arrival spacing (EWMA, 4–12 frames =
  80–240 ms). Bursts past the high-water mark are caught up by trimming to
  the target (bounded accumulated delay); a 50-frame hard cap remains as the
  safety bound. Synthetic tests: steady streams hold the low target; 100 ms
  network batching raises it without unbounded growth.
- **Bounded basic PLC fallback** (`WSPlaybackScheduler`): on a genuine
  underrun while recent real audio played, repeats the last **scheduled**
  frame (playback timeline, never the newest queued input) with exponential
  decay (0.8ⁿ) and **sign alternation** (anti-buzz), max 5 ticks per chain.
  **This is NOT NetEq or G.711 Appendix I** — it is an honestly-labeled
  basic fallback. Seed discipline: every scheduled frame updates the seed
  and **silence clears it**, so an underrun during true silence can never
  replay stale speech (tested).
- **Capture-conservation evidence** (`WSCapturePipeline` + graph stop log):
  per-run `capMinPct` — the rolling-window ratio of delivered samples vs
  wall time × source rate (resets on mute/flush; windowed so a healthy
  opening minute cannot mask later starvation; census uses a true
  cross-run MINIMUM). This is the discriminator for the field-reported
  periodic 200-on/200-off uplink: a starved capture records ≪100, a healthy
  batched capture ≈100. **No restart is armed from it** — no synthetic
  repro proved a restart repairs that class, and restarts already hurt this
  user once.
- **Synthetic continuity suite** (`WSCaptureContinuityTests`): continuous
  440 Hz tone through the real capture pipeline + real AVAudioConverter at
  48 kHz and 44.1 kHz: steady 20 ms, 100 ms, 200 ms and 400 ms bursts all
  produce zero periodic dropouts after bounded priming with sample
  conservation; the exact 200-on/200-off duty cycle is reproduced only when
  the SOURCE starves, and the pipeline mirrors it without amplification
  (10-tick silent runs, never longer; backlogs bounded by construction).

### Gateway (Go, pion)
- **NACK both directions** (`media.NewEngine`): PCMU registered with
  `rtcp-fb nack` + transport-cc feedback and the TWCC header extension; the
  pion interceptor chain adds a NACK responder (answers the client's
  retransmission requests — downlink loss recovery) and generator (requests
  retransmission for client→gateway losses). The app's SDP codec filter
  preserves these lines for payload type 0, and the Google WebRTC SDK
  handles NACK automatically — no client change needed.
- **Playout deadline for retransmissions** (`Session.hostPush`): frames
  whose RTP timestamp already fell behind the play cursor are dropped
  before entering the jitter buffer (same rule the WSS socket path
  applies); duplicates are idempotent; depth stays ≤ target (tested).
- **RTCP Sender/Receiver Reports** registered (clock/loss accounting both
  ways).
- **Congestion-feedback observer** (`rrObserver`): consumes the Receiver
  Reports the client SDK emits and logs bounded per-SSRC windows
  (fraction-lost, jitter) as measured by the phone. Consumed through the
  real interceptor chain (tested); the production OnTrack path now drives
  `receiver.ReadRTCP()` so the chain actually runs.

## 3. What is NOT closed-loop (honest status, build 26)

- The **WSS relay path** stays PCMU over TCP: TCP retransmit hides loss as
  delay, and there is no bitrate to adapt. Its bounded jitter buffer remains
  the only latency control; no fake "congestion control" is claimed there.
- **PCMU fallback sessions** (old app ↔ new gateway, or any PCMU answer)
  keep NACK/RR as loss handling with no bitrate controller — G.711 is
  fixed-rate.
- **Physical validation pending**: adaptation behavior under real cellular
  loss/jitter and the 200 ms uplink symptom needs field evidence from the
  app's diagnostics (`capMinPct`, `tapGapMsMax`, `io=` line) on build 26.

## 4. Remaining mature components — status after build 26

1. ~~Opus on the network hop~~ — **done** (§0): libopus at the media edge,
   offer-driven negotiation, PCMU fallback, inband FEC + usedtx advertised.
2. ~~Closed-loop congestion control~~ — **done for the downlink** (§0):
   GCC estimate → bitrate CTL; RR loss → loss-perc + FEC; uplink NACK
   budget is direction-local. Uplink bitrate adaptation is the phone SDK's
   sender-side estimator fed by the gateway's TWCC sender interceptor.
3. **Receiver-side NetEq-class buffer**: still the honest remaining item.
   The gateway now uses mature libopus PLC (`opus_decode` with a nil
   packet) for NACK gaps; the app's bounded fallback stays the interim on
   the WSS path. Porting NetEq itself is a large C++ integration that
   remains unjustified until field evidence says the current bounded
   buffer + PLC underperforms.

## 5. QUIC: unchanged (user decision)

The frp tunnel is HTTPS/WSS-only (no UDP). WebTransport would require
HTTP/3 (UDP 443) end-to-end; frpc–frps QUIC transport is a tunnel-internal
detail and does NOT extend to the app hop. No QUIC work is done or planned.
