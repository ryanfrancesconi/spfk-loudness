// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AudioToolbox
import Foundation
import SPFKAudioBase
import SPFKBase

extension LoudnessAnalyzer {
    /// Analyzes decoded PCM and returns its EBU R128 loudness metrics.
    ///
    /// The counterpart to ``analyze(url:minimumDuration:isCancelled:)`` for audio `ExtAudioFile`
    /// cannot reach. The source is read to its end, so a container that overstates its length is
    /// measured on what it holds. A source of unknown length is never looped.
    ///
    /// - Throws: `CancellationError` when `isCancelled` fires, or the source's own error.
    public static func analyze(
        pcmSource: some SequentialPCMSource,
        minimumDuration: TimeInterval? = nil,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> LoudnessDescription {
        let format = pcmSource.processingFormat

        var clientASBD = AudioStreamBasicDescription()
        clientASBD.mChannelsPerFrame = format.channelCount
        clientASBD.mSampleRate = format.sampleRate
        clientASBD.mFormatID = kAudioFormatLinearPCM
        clientASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        clientASBD.mBitsPerChannel = 32
        clientASBD.mFramesPerPacket = 1
        clientASBD.mBytesPerFrame = 4 * clientASBD.mChannelsPerFrame
        clientASBD.mBytesPerPacket = clientASBD.mBytesPerFrame

        let loops = loops(
            lengthInFrames: max(0, pcmSource.totalFrameCount),
            sampleRate: format.sampleRate,
            minimumDuration: minimumDuration
        )

        let reader = try PCMSourceFrameReader(source: pcmSource, retainsFramesForLooping: loops)

        return try analyze(
            reader: reader,
            clientASBD: clientASBD,
            loops: loops,
            minimumDuration: minimumDuration,
            isCancelled: isCancelled
        )
    }
}
