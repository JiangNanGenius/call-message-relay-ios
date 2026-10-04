import Foundation

/// WSS-Opus wire framing (build 27, negotiated as `fmt=seq16` in the ready
/// control). Each binary message is [seq: 2 bytes big-endian][Opus payload].
/// The sequence counts 20 ms MEDIA SLOTS, not sent frames: sender-side drops
/// (bounded-queue stale drops, encoder failures) leave holes the receiver
/// conceals with mature PLC, keeping the stateful decoder's timeline aligned.
/// Legacy PCMU stays the bare 160-byte frame and is untouched.
enum WSSFrameCodec {
    /// One-slot-per-20ms bound on PLC work per gap (a stalled socket must
    /// not produce minutes of concealment in one burst).
    static let maxGapSlots = 50

    static func frame(seq: UInt16, payload: [UInt8]) -> Data {
        var out = Data(count: 2 + payload.count)
        out[0] = UInt8(seq >> 8)
        out[1] = UInt8(seq & 0xff)
        out.replaceSubrange(2..., with: payload)
        return out
    }

    /// Parse one framed message; nil when too short to carry a header.
    static func parse(_ data: Data) -> (seq: UInt16, payload: [UInt8])? {
        guard data.count >= 3 else { return nil }
        let seq = UInt16(data[0]) << 8 | UInt16(data[1])
        return (seq, Array(data.dropFirst(2)))
    }

    enum Slot {
        /// Decode this payload normally at this slot.
        case decode([UInt8])
        /// Missed slot: mature PLC (decode nil).
        case plc
        /// Recover the missed PREDECESSOR from this carrier's RFC 7587
        /// inband FEC (the carrier itself is decoded by the following
        /// `.decode` slot, exactly once).
        case fecRecover([UInt8])
    }

    /// Gap-aware depacketizer: consumes sequence numbers and emits the work
    /// list per received message. Duplicates and obsolete frames emit
    /// nothing (the decoder must never advance twice for one slot).
    struct Depacketizer {
        private var state: UInt16 = 0
        private var seeded = false

        init() {}

        mutating func arrivals(seq: UInt16, payload: [UInt8]) -> [Slot] {
            if !seeded {
                state = seq
                seeded = true
                return [.decode(payload)]
            }
            // Wrap-aware ordering (matches the gateway's wsDepacketize).
            let d = Int16(bitPattern: seq &- state)
            guard d > 0 else { return [] }
            var slots: [Slot] = []
            let gap = Int(d) - 1
            if gap == 1 {
                slots.append(.fecRecover(payload))
            } else {
                for _ in 0..<min(gap, WSSFrameCodec.maxGapSlots) {
                    slots.append(.plc)
                }
            }
            slots.append(.decode(payload))
            state = seq
            return slots
        }
    }
}
