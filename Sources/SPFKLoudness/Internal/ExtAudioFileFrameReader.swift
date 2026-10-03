// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AudioToolbox
import Foundation

/// Reads a file's first audio track through `ExtAudioFile`, converted to interleaved Float32.
final class ExtAudioFileFrameReader: FrameReader {
    private let audioFileRef: ExtAudioFileRef
    let clientASBD: AudioStreamBasicDescription
    let lengthInFrames: Int64
    let channelLabels: [AudioChannelLabel]?

    init(url: URL) throws {
        let audioFileRef = try Self.openAudioFile(url: url)

        do {
            clientASBD = try Self.configureClientFormat(for: audioFileRef)
        } catch {
            ExtAudioFileDispose(audioFileRef)
            throw error
        }

        self.audioFileRef = audioFileRef

        var length: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        let err = ExtAudioFileGetProperty(audioFileRef, kExtAudioFileProperty_FileLengthFrames, &size, &length)
        lengthInFrames = length
        channelLabels = Self.fileChannelLabels(of: audioFileRef)

        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
    }

    deinit {
        ExtAudioFileDispose(audioFileRef)
    }

    func read(into buffer: UnsafeMutablePointer<Float32>, frameCount: UInt32) throws -> UInt32 {
        var frames = frameCount

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: clientASBD.mChannelsPerFrame,
                mDataByteSize: frameCount * clientASBD.mBytesPerFrame,
                mData: buffer
            )
        )

        let err = ExtAudioFileRead(audioFileRef, &frames, &bufferList)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        return frames
    }

    func rewind() throws {
        let err = ExtAudioFileSeek(audioFileRef, 0)
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }
    }
}

extension ExtAudioFileFrameReader {
    /// Opens an audio file for reading via Extended Audio File Services.
    fileprivate static func openAudioFile(url: URL) throws -> ExtAudioFileRef {
        var audioFileRef: ExtAudioFileRef?
        let err = ExtAudioFileOpenURL(url as CFURL, &audioFileRef)

        guard err == noErr, let audioFileRef else {
            throw NSError(
                domain: NSOSStatusErrorDomain, code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "Failed to open '\(url.lastPathComponent)' (OSStatus \(err))"]
            )
        }
        return audioFileRef
    }

    /// Reads the file's native format and sets the client format to Float32 interleaved PCM.
    fileprivate static func configureClientFormat(for audioFileRef: ExtAudioFileRef) throws -> AudioStreamBasicDescription {
        var inFileASBD = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        var err = ExtAudioFileGetProperty(
            audioFileRef,
            kExtAudioFileProperty_FileDataFormat,
            &propSize,
            &inFileASBD
        )
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        var clientASBD = AudioStreamBasicDescription()
        clientASBD.mChannelsPerFrame = inFileASBD.mChannelsPerFrame
        clientASBD.mSampleRate = inFileASBD.mSampleRate
        clientASBD.mFormatID = kAudioFormatLinearPCM
        clientASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        clientASBD.mBitsPerChannel = 32
        clientASBD.mFramesPerPacket = 1
        clientASBD.mBytesPerFrame = 4 * clientASBD.mChannelsPerFrame
        clientASBD.mBytesPerPacket = clientASBD.mBytesPerFrame
        propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        err = ExtAudioFileSetProperty(
            audioFileRef,
            kExtAudioFileProperty_ClientDataFormat,
            propSize,
            &clientASBD
        )
        guard err == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(err)) }

        return clientASBD
    }

    /// The file's declared channel layout, expanded to one label per channel.
    fileprivate static func fileChannelLabels(of audioFileRef: ExtAudioFileRef) -> [AudioChannelLabel]? {
        var size: UInt32 = 0

        // A layout named by tag or bitmap carries no descriptions, so the property is only the
        // header — shorter than `AudioChannelLayout`, which declares room for one.
        guard ExtAudioFileGetPropertyInfo(audioFileRef, kExtAudioFileProperty_FileChannelLayout, &size, nil) == noErr,
              let header = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions),
              size >= UInt32(header)
        else { return nil }

        let byteCount = max(Int(size), MemoryLayout<AudioChannelLayout>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { raw.deallocate() }

        guard ExtAudioFileGetProperty(audioFileRef, kExtAudioFileProperty_FileChannelLayout, &size, raw) == noErr else {
            return nil
        }

        return ChannelMap.labels(of: raw.assumingMemoryBound(to: AudioChannelLayout.self))
    }
}
