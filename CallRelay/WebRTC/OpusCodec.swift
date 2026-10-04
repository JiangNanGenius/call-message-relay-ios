import Foundation
import Opus

/// Reference libopus (Xiph.Org, BSD-3-Clause — see Vendor/opus/COPYING) for
/// the WSS relay path. The direct WebRTC path encodes Opus inside the WebRTC
/// SDK; the WSS socket is app-level, so the app owns the codec there.
/// Narrowband 8 kHz mono with 20 ms frames matches the PCM domain shared
/// with the playback scheduler and capture pipeline.
enum OpusCodec {
    static let sampleRate = 8000
    static let channels = 1
    static let frameSamples = 160 // 20 ms @ 8 kHz
    static let maxFrameBytes = 400

    static var version: String {
        String(cString: opus_get_version_string())
    }

    enum OpusError: Error {
        case createFailed(String)
        case encodeFailed(String)
        case decodeFailed(String)
        case ctlFailed(String)
    }

    /// Encoder for one direction of one call. Not thread-safe: each call
    /// path owns its instance and touches it from a single queue.
    final class Encoder {
        private var state: OpaquePointer?

        init() throws {
            var err: opus_int32 = OPUS_OK
            guard let st = opus_encoder_create(
                opus_int32(OpusCodec.sampleRate),
                Int32(OpusCodec.channels),
                Int32(OPUS_APPLICATION_VOIP),
                &err
            ), err == OPUS_OK else {
                throw OpusError.createFailed(Self.message(err))
            }
            state = st
            // Gateway defaults: inband FEC on, DTX on (advertised over the
            // WSS handshake), 32 kbps initial (the controllers adapt it).
            try setInt(OPUS_SET_BITRATE_REQUEST, 32000)
            try setInt(OPUS_SET_INBAND_FEC_REQUEST, 1)
            try setInt(OPUS_SET_DTX_REQUEST, 1)
        }

        deinit { close() }

        func close() {
            if let st = state {
                opus_encoder_destroy(st)
                state = nil
            }
        }

        /// Encode exactly one 20 ms frame. The output is copied; callers may
        /// retain it beyond the next encode.
        func encode(_ pcm: [Int16]) throws -> [UInt8] {
            guard pcm.count == OpusCodec.frameSamples else {
                throw OpusError.encodeFailed("expected \(OpusCodec.frameSamples) samples, got \(pcm.count)")
            }
            guard let st = state else { throw OpusError.encodeFailed("closed") }
            var out = [UInt8](repeating: 0, count: OpusCodec.maxFrameBytes)
            let n = pcm.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    opus_encode(
                        st,
                        src.baseAddress!,
                        Int32(OpusCodec.frameSamples),
                        dst.baseAddress!,
                        opus_int32(dst.count)
                    )
                }
            }
            guard n >= 0 else { throw OpusError.encodeFailed(Self.message(n)) }
            return Array(out.prefix(Int(n)))
        }

        func setBitrate(_ bps: Int) throws {
            guard bps > 0, bps <= 512_000 else { throw OpusError.ctlFailed("bitrate \(bps)") }
            try setInt(OPUS_SET_BITRATE_REQUEST, opus_int32(bps))
        }

        func setPacketLossPerc(_ p: Int) throws {
            guard (0...100).contains(p) else { throw OpusError.ctlFailed("loss \(p)") }
            try setInt(OPUS_SET_PACKET_LOSS_PERC_REQUEST, opus_int32(p))
        }

        func setInbandFEC(_ enabled: Bool) throws {
            try setInt(OPUS_SET_INBAND_FEC_REQUEST, enabled ? 1 : 0)
        }

        private func setInt(_ request: Int32, _ value: opus_int32) throws {
            guard let st = state else { throw OpusError.ctlFailed("closed") }
            let rc: CInt
            switch request {
            case OPUS_SET_BITRATE_REQUEST:
                rc = callrelay_opus_enc_set_bitrate(st, value)
            case OPUS_SET_PACKET_LOSS_PERC_REQUEST:
                rc = callrelay_opus_enc_set_loss_perc(st, value)
            case OPUS_SET_INBAND_FEC_REQUEST:
                rc = callrelay_opus_enc_set_fec(st, value)
            case OPUS_SET_DTX_REQUEST:
                rc = callrelay_opus_enc_set_dtx(st, value)
            case OPUS_SET_COMPLEXITY_REQUEST:
                rc = callrelay_opus_enc_set_complexity(st, value)
            default:
                throw OpusError.ctlFailed("unsupported request \(request)")
            }
            guard rc == OPUS_OK else { throw OpusError.ctlFailed(Self.message(rc)) }
        }

        static func message(_ code: opus_int32) -> String {
            String(cString: opus_strerror(code))
        }
    }

    /// Decoder for one direction of one call. Not thread-safe.
    final class Decoder {
        private var state: OpaquePointer?

        init() throws {
            var err: opus_int32 = OPUS_OK
            guard let st = opus_decoder_create(
                opus_int32(OpusCodec.sampleRate),
                Int32(OpusCodec.channels),
                &err
            ), err == OPUS_OK else {
                throw OpusError.createFailed(Self.message(err))
            }
            state = st
        }

        deinit { close() }

        func close() {
            if let st = state {
                opus_decoder_destroy(st)
                state = nil
            }
        }

        /// Decode one frame; nil performs packet-loss concealment (the
        /// mature libopus PLC used for WSS gaps).
        func decode(_ packet: [UInt8]?) throws -> [Int16] {
            guard let st = state else { throw OpusError.decodeFailed("closed") }
            var out = [Int16](repeating: 0, count: OpusCodec.frameSamples)
            let n: opus_int32
            if let packet, !packet.isEmpty {
                n = packet.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { dst in
                        opus_decode(
                            st,
                            src.baseAddress!,
                            opus_int32(src.count),
                            dst.baseAddress!,
                            Int32(OpusCodec.frameSamples),
                            0
                        )
                    }
                }
            } else {
                n = out.withUnsafeMutableBufferPointer { dst in
                    opus_decode(st, nil, 0, dst.baseAddress!, Int32(OpusCodec.frameSamples), 0)
                }
            }
            guard n >= 0 else { throw OpusError.decodeFailed(Self.message(n)) }
            return Array(out.prefix(Int(n)))
        }

        /// Recover the PREVIOUS frame from this packet's RFC 7587 inband FEC
        /// redundancy WITHOUT consuming the packet (it decodes normally at
        /// its own slot right after). libopus degrades gracefully when no
        /// FEC is embedded, so the caller always gets a full slot's audio.
        func decodeFEC(_ packet: [UInt8]) throws -> [Int16] {
            guard let st = state else { throw OpusError.decodeFailed("closed") }
            guard !packet.isEmpty else { throw OpusError.decodeFailed("empty fec carrier") }
            var out = [Int16](repeating: 0, count: OpusCodec.frameSamples)
            let n = packet.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    opus_decode(
                        st,
                        src.baseAddress!,
                        opus_int32(src.count),
                        dst.baseAddress!,
                        Int32(OpusCodec.frameSamples),
                        1
                    )
                }
            }
            guard n >= 0 else { throw OpusError.decodeFailed(Self.message(n)) }
            return Array(out.prefix(Int(n)))
        }

        static func message(_ code: opus_int32) -> String {
            String(cString: opus_strerror(code))
        }
    }
}
