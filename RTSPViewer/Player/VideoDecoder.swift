import AVFoundation
import CoreMedia
import Foundation

/// Reassembles H.264/H.265 pictures and enqueues them to the display layer's renderer
/// (which decodes them in hardware). Called on the player's queue.
final class VideoDecoder {
    private let renderer: AVSampleBufferVideoRenderer
    private var codec: VideoCodec = .h264
    private var depacketizer: RTPDepacketizer?
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true

    private(set) var dimensions: CMVideoDimensions?

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    func configure(track: VideoTrack) {
        if track.codec != codec {
            vps = nil
            sps = nil
            pps = nil
            formatDescription = nil
        }
        codec = track.codec
        depacketizer = RTPDepacketizer(codec: track.codec)
        waitingForKeyframe = true
        for parameterSet in track.parameterSets {
            _ = storeParameterSet(parameterSet)
        }
    }

    func reset() {
        renderer.flush()
        waitingForKeyframe = true
        depacketizer = nil
    }

    func checkHealth() {
        if renderer.status == .failed {
            renderer.flush()
            waitingForKeyframe = true
        }
    }

    func accessUnits(from packet: RTPPacket) -> [AccessUnit] {
        depacketizer?.push(packet) ?? []
    }

    /// Enqueues the picture for display at `time`. Returns false when it was dropped
    /// (corrupted, or waiting for the next keyframe).
    func decode(_ unit: AccessUnit, at time: Double) -> Bool {
        if unit.isCorrupted {
            waitingForKeyframe = true
            return false
        }

        var sampleNALs: [[UInt8]] = []
        var hasPicture = false
        var isKeyframe = false
        for nal in unit.nalUnits where !nal.isEmpty {
            if storeParameterSet(nal) {
                continue
            }
            switch codec {
            case .h264:
                let type = nal[0] & 0x1F
                if type == 9 || type == 12 { // access unit delimiter, filler
                    continue
                }
                if type >= 1 && type <= 5 {
                    hasPicture = true
                }
                if type == 5 {
                    isKeyframe = true
                }
            case .h265:
                let type = (nal[0] >> 1) & 0x3F
                if type == 35 || type == 38 { // access unit delimiter, filler
                    continue
                }
                if type <= 31 {
                    hasPicture = true
                }
                if type >= 16 && type <= 21 {
                    isKeyframe = true
                }
            }
            sampleNALs.append(nal)
        }
        guard hasPicture else { return false }

        if waitingForKeyframe {
            guard isKeyframe else { return false }
            waitingForKeyframe = false
        }

        if formatDescription == nil {
            formatDescription = makeFormatDescription()
            if let formatDescription {
                dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            }
        }
        guard let format = formatDescription else {
            waitingForKeyframe = true
            return false
        }

        if renderer.status == .failed {
            renderer.flush()
            guard isKeyframe else {
                waitingForKeyframe = true
                return false
            }
        }

        guard let sample = SampleBufferFactory.videoSampleBuffer(
            nalUnits: sampleNALs,
            format: format,
            presentationTime: time,
            isKeyframe: isKeyframe
        ) else { return false }

        renderer.enqueue(sample)
        return true
    }

    // MARK: - Parameter sets

    private func storeParameterSet(_ nal: [UInt8]) -> Bool {
        guard let header = nal.first else { return false }
        switch codec {
        case .h264:
            switch header & 0x1F {
            case 7: replace(&sps, with: nal)
            case 8: replace(&pps, with: nal)
            default: return false
            }
        case .h265:
            switch (header >> 1) & 0x3F {
            case 32: replace(&vps, with: nal)
            case 33: replace(&sps, with: nal)
            case 34: replace(&pps, with: nal)
            default: return false
            }
        }
        return true
    }

    private func replace(_ slot: inout [UInt8]?, with value: [UInt8]) {
        guard slot != value else { return }
        slot = value
        formatDescription = nil
    }

    private func makeFormatDescription() -> CMVideoFormatDescription? {
        switch codec {
        case .h264:
            guard let sps, let pps else { return nil }
            return SampleBufferFactory.videoFormatDescription(parameterSets: [sps, pps], codec: .h264)
        case .h265:
            guard let vps, let sps, let pps else { return nil }
            return SampleBufferFactory.videoFormatDescription(parameterSets: [vps, sps, pps], codec: .h265)
        }
    }
}
