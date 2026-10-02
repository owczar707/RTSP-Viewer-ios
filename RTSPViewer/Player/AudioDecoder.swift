import AVFoundation
import CoreMedia
import Foundation

/// One encoded audio frame together with its RTP timestamp.
struct AudioFrame {
    let timestamp: UInt32
    let bytes: [UInt8]
}

/// Unpacks AAC / G.711 / L16 from RTP, decodes it to 16-bit PCM and enqueues it to the
/// audio renderer. Called on the player's queue.
final class AudioDecoder {
    let track: AudioTrack

    private let renderer: AVSampleBufferAudioRenderer
    private let channels: Int
    private let sampleRate: Double
    private let formatDescription: CMAudioFormatDescription
    private var aacInputFormat: AVAudioFormat?
    private var aacOutputFormat: AVAudioFormat?
    private var aacConverter: AVAudioConverter?
    private var latmBuffer: [UInt8] = []
    private var latmTimestamp: UInt32 = 0

    init?(track: AudioTrack, renderer: AVSampleBufferAudioRenderer) {
        guard track.sampleRate > 0,
              let format = SampleBufferFactory.pcmFormatDescription(sampleRate: track.sampleRate, channels: track.channels)
        else { return nil }

        self.track = track
        self.renderer = renderer
        self.channels = track.channels
        self.sampleRate = track.sampleRate
        self.formatDescription = format

        if track.isAAC {
            var description = AudioStreamBasicDescription(
                mSampleRate: track.sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 1024,
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(track.channels),
                mBitsPerChannel: 0,
                mReserved: 0
            )
            guard let input = AVAudioFormat(streamDescription: &description),
                  let output = AVAudioFormat(
                      commonFormat: .pcmFormatInt16,
                      sampleRate: track.sampleRate,
                      channels: AVAudioChannelCount(track.channels),
                      interleaved: true
                  ),
                  let converter = AVAudioConverter(from: input, to: output) else { return nil }
            aacInputFormat = input
            aacOutputFormat = output
            aacConverter = converter
        }
    }

    func resetDepacketizer() {
        latmBuffer.removeAll()
    }

    // MARK: - Depacketizing

    func frames(from packet: RTPPacket) -> [AudioFrame] {
        switch track.format {
        case .pcmu, .pcma, .l16:
            return [AudioFrame(timestamp: packet.timestamp, bytes: packet.payload)]
        case let .aacGeneric(sizeLength, indexLength, indexDeltaLength):
            return framesRFC3640(
                packet,
                sizeLength: sizeLength,
                indexLength: indexLength,
                indexDeltaLength: indexDeltaLength
            )
        case .aacLATM:
            if latmBuffer.isEmpty {
                latmTimestamp = packet.timestamp
            }
            latmBuffer.append(contentsOf: packet.payload)
            guard packet.marker else { return [] }
            let frames = framesLATM(latmBuffer, timestamp: latmTimestamp)
            latmBuffer.removeAll(keepingCapacity: true)
            return frames
        }
    }

    /// RFC 3640: AU-headers-length, AU headers (size + index), then the AAC frames.
    private func framesRFC3640(_ packet: RTPPacket, sizeLength: Int, indexLength: Int, indexDeltaLength: Int) -> [AudioFrame] {
        let payload = packet.payload
        guard sizeLength > 0, payload.count > 2 else { return [] }
        let headerBits = (Int(payload[0]) << 8) | Int(payload[1])
        let headerBytes = (headerBits + 7) / 8
        guard 2 + headerBytes <= payload.count else { return [] }

        var reader = BitReader(payload, byteOffset: 2)
        var sizes: [Int] = []
        var bitsRead = 0
        while true {
            let indexBits = sizes.isEmpty ? indexLength : indexDeltaLength
            guard bitsRead + sizeLength + indexBits <= headerBits else { break }
            sizes.append(reader.read(sizeLength))
            _ = reader.read(indexBits)
            bitsRead += sizeLength + indexBits
        }

        var frames: [AudioFrame] = []
        var offset = 2 + headerBytes
        var timestamp = packet.timestamp
        for size in sizes {
            guard size > 0, offset + size <= payload.count else { break }
            frames.append(AudioFrame(timestamp: timestamp, bytes: Array(payload[offset..<(offset + size)])))
            offset += size
            timestamp &+= track.ticksPerAACFrame
        }
        return frames
    }

    /// RFC 3016 (cpresent=0): PayloadLengthInfo (0xFF-continued length) + AAC frame.
    private func framesLATM(_ data: [UInt8], timestamp: UInt32) -> [AudioFrame] {
        var frames: [AudioFrame] = []
        var index = 0
        var frameTimestamp = timestamp
        while index < data.count {
            var length = 0
            while index < data.count {
                let byte = data[index]
                index += 1
                length += Int(byte)
                if byte != 0xFF {
                    break
                }
            }
            guard length > 0, index + length <= data.count else { break }
            frames.append(AudioFrame(timestamp: frameTimestamp, bytes: Array(data[index..<(index + length)])))
            index += length
            frameTimestamp &+= track.ticksPerAACFrame
        }
        return frames
    }

    // MARK: - Decoding

    /// Decodes and enqueues the frame at `time`. Returns the duration of the enqueued audio.
    func decode(_ frame: AudioFrame, at time: Double) -> Double? {
        let samples: [Int16]
        switch track.format {
        case .pcmu:
            samples = frame.bytes.map { G711.muLaw[Int($0)] }
        case .pcma:
            samples = frame.bytes.map { G711.aLaw[Int($0)] }
        case .l16:
            var decoded: [Int16] = []
            decoded.reserveCapacity(frame.bytes.count / 2)
            var index = 0
            while index + 1 < frame.bytes.count {
                let value = (UInt16(frame.bytes[index]) << 8) | UInt16(frame.bytes[index + 1])
                decoded.append(Int16(bitPattern: value))
                index += 2
            }
            samples = decoded
        case .aacGeneric, .aacLATM:
            guard let decoded = decodeAAC(frame.bytes) else { return nil }
            samples = decoded
        }

        let frameCount = samples.count / channels
        guard frameCount > 0 else { return nil }
        let usableSamples = frameCount * channels == samples.count ? samples : Array(samples.prefix(frameCount * channels))

        guard let sample = SampleBufferFactory.pcmSampleBuffer(
            samples: usableSamples,
            frameCount: frameCount,
            format: formatDescription,
            presentationTime: CMTime(seconds: time, preferredTimescale: CMTimeScale(sampleRate.rounded()))
        ) else { return nil }

        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sample)
        return Double(frameCount) / sampleRate
    }

    private func decodeAAC(_ bytes: [UInt8]) -> [Int16]? {
        guard !bytes.isEmpty,
              let converter = aacConverter,
              let inputFormat = aacInputFormat,
              let outputFormat = aacOutputFormat else { return nil }

        let input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: bytes.count)
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                input.data.copyMemory(from: base, byteCount: raw.count)
            }
        }
        input.byteLength = UInt32(bytes.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(bytes.count)
        )

        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return nil }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0, let data = output.int16ChannelData else { return nil }
        let count = Int(output.frameLength) * channels
        return Array(UnsafeBufferPointer(start: data[0], count: count))
    }
}

/// G.711 lookup tables (ITU-T reference decoder).
private enum G711 {
    static let muLaw: [Int16] = (0..<256).map { G711.decodeMuLaw(UInt8($0)) }
    static let aLaw: [Int16] = (0..<256).map { G711.decodeALaw(UInt8($0)) }

    private static func decodeMuLaw(_ value: UInt8) -> Int16 {
        let inverted = ~value
        let exponent = Int((inverted >> 4) & 0x07)
        let mantissa = Int(inverted & 0x0F)
        let magnitude = (((mantissa << 3) + 0x84) << exponent) - 0x84
        return Int16(inverted & 0x80 != 0 ? -magnitude : magnitude)
    }

    private static func decodeALaw(_ value: UInt8) -> Int16 {
        let toggled = value ^ 0x55
        var magnitude = Int(toggled & 0x0F) << 4
        let segment = Int((toggled & 0x70) >> 4)
        switch segment {
        case 0:
            magnitude += 8
        case 1:
            magnitude += 0x108
        default:
            magnitude += 0x108
            magnitude <<= (segment - 1)
        }
        return Int16(toggled & 0x80 != 0 ? magnitude : -magnitude)
    }
}
