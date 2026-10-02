import AudioToolbox
import CoreMedia
import Foundation

/// Builds CoreMedia objects from raw NAL units and PCM samples.
enum SampleBufferFactory {
    // MARK: - Video

    static func videoFormatDescription(parameterSets: [[UInt8]], codec: VideoCodec) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }

        // The CoreMedia API needs all pointers alive at the same time, so copy into stable buffers.
        let buffers: [UnsafeMutablePointer<UInt8>] = parameterSets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer {
            buffers.forEach { $0.deallocate() }
        }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes: [Int] = parameterSets.map { $0.count }

        var format: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format
            )
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    /// Packs NAL units as length-prefixed AVCC/HVCC data into a ready sample buffer.
    static func videoSampleBuffer(
        nalUnits: [[UInt8]],
        format: CMVideoFormatDescription,
        presentationTime: Double,
        isKeyframe: Bool
    ) -> CMSampleBuffer? {
        var data: [UInt8] = []
        data.reserveCapacity(nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            let length = UInt32(nal.count)
            data.append(UInt8(truncatingIfNeeded: length >> 24))
            data.append(UInt8(truncatingIfNeeded: length >> 16))
            data.append(UInt8(truncatingIfNeeded: length >> 8))
            data.append(UInt8(truncatingIfNeeded: length))
            data.append(contentsOf: nal)
        }
        guard let blockBuffer = data.withUnsafeBytes({ makeBlockBuffer(copying: $0) }) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: presentationTime, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if !isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    // MARK: - Audio

    /// Interleaved signed 16-bit PCM.
    static func pcmFormatDescription(sampleRate: Double, channels: Int) -> CMAudioFormatDescription? {
        let bytesPerFrame = UInt32(2 * channels)
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    static func pcmSampleBuffer(
        samples: [Int16],
        frameCount: Int,
        format: CMAudioFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        guard let blockBuffer = samples.withUnsafeBytes({ makeBlockBuffer(copying: $0) }) else { return nil }
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }

    // MARK: - Helpers

    private static func makeBlockBuffer(copying bytes: UnsafeRawBufferPointer) -> CMBlockBuffer? {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        status = CMBlockBufferReplaceDataBytes(
            with: base,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: bytes.count
        )
        return status == kCMBlockBufferNoErr ? blockBuffer : nil
    }
}
