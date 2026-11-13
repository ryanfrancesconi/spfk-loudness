// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Accelerate
import AudioToolbox
import Foundation
import SPFKAudioBase
import SPFKLoudnessC

/// One analysis: the oversampling converter, the libebur128 state and what they have measured.
///
/// Driven one ``convert()`` at a time, so a caller whose reader starves can await a refill between
/// conversions.
final class AnalysisSession {
    enum Step {
        /// Output was produced and more input remains.
        case produced
        /// The reader must be refilled before the next conversion.
        case starved
        case finished
    }

    private let converter: LoudnessAnalyzer.ConverterResources
    private let state: UnsafeMutablePointer<ebur128_state>
    private let context: UnsafeMutablePointer<CallbackContext>
    private let handle: AnalysisHandle
    private let usesDeclaredChannelLayout: Bool
    private var maxTruePeak: Float32 = 0

    init(
        reader: any FrameReader,
        clientASBD: AudioStreamBasicDescription,
        loops: Bool,
        minimumDuration: TimeInterval?
    ) throws {
        let overSamplingFactor: UInt32 = if clientASBD.mSampleRate <= 48000 {
            4
        } else if clientASBD.mSampleRate <= 96000 {
            2
        } else {
            1
        }

        let converter = try LoudnessAnalyzer.createConverter(clientASBD: clientASBD, overSamplingFactor: overSamplingFactor)
        let state: UnsafeMutablePointer<ebur128_state>

        do {
            state = try LoudnessAnalyzer.createEBUR128State(
                channelCount: clientASBD.mChannelsPerFrame,
                sampleRate: clientASBD.mSampleRate
            )
        } catch {
            converter.dispose()
            throw error
        }

        let channelMap = reader.channelLabels
            .flatMap(ChannelMap.ebur128Channels(for:))
            .flatMap { $0.count == Int(clientASBD.mChannelsPerFrame) ? $0 : nil }

        for (index, channel) in (channelMap ?? []).enumerated() {
            ebur128_set_channel(state, UInt32(index), channel)
        }

        let handle = AnalysisHandle(reader: reader)

        context = .allocate(capacity: 1)
        context.initialize(to: LoudnessAnalyzer.makeContext(
            handle: handle,
            fileOutBuffer: converter.inputBuffer,
            state: state,
            clientASBD: clientASBD,
            loops: loops,
            minimumDuration: minimumDuration
        ))

        self.converter = converter
        self.state = state
        self.handle = handle
        usesDeclaredChannelLayout = channelMap != nil
    }

    deinit {
        context.deinitialize(count: 1)
        context.deallocate()

        var state: UnsafeMutablePointer<ebur128_state>? = state
        ebur128_destroy(&state)

        converter.dispose()
    }

    /// Fills the converter's output once, pulling input through ``audioConverterCallback``, and
    /// tracks the true peak of what came out.
    func convert() throws -> Step {
        let outputASBD = converter.outputASBD
        var frames = converter.outputFrameCount

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: outputASBD.mChannelsPerFrame,
                mDataByteSize: frames * outputASBD.mBytesPerFrame,
                mData: UnsafeMutableRawPointer(converter.outputBuffer)
            )
        )

        let status = AudioConverterFillComplexBuffer(
            converter.ref,
            audioConverterCallback,
            context,
            &frames,
            &bufferList,
            nil
        )

        if let error = handle.error {
            throw error
        }

        let isStarved = status == audioConverterStarvedStatus

        if status != noErr, status != kAudioConverterErr_InvalidInputSize, !isStarved {
            throw LoudnessAnalyzer.osStatusError(status)
        }

        if frames > 0 {
            let samples = UnsafeMutableRawPointer(converter.outputBuffer).assumingMemoryBound(to: Float32.self)

            var blockMax: Float32 = 0
            vDSP_maxmgv(samples, 1, &blockMax, vDSP_Length(frames * bufferList.mBuffers.mNumberChannels))

            maxTruePeak = max(maxTruePeak, blockMax)
        }

        // A starved conversion says nothing about the end: the source is read until it is empty.
        if isStarved { return .starved }

        if frames == 0 { return .finished }

        return context.pointee.fileFramesRead < context.pointee.targetFrames ? .produced : .finished
    }

    var measurement: LoudnessMeasurement {
        LoudnessMeasurement(
            description: description,
            gatingBlocks: handle.gatingBlocks,
            usesDeclaredChannelLayout: usesDeclaredChannelLayout
        )
    }

    private var description: LoudnessDescription {
        var il: Float64 = 0
        ebur128_loudness_global(state, &il)
        il = rint(100 * il) / 100

        var lra: Float64 = 0
        ebur128_loudness_range(state, &lra)
        lra = rint(100 * lra) / 100

        let truePeakDBTP = rintf(100 * 20 * log10(maxTruePeak)) / 100
        let context = context.pointee

        return LoudnessDescription(
            loudnessIntegrated: il,
            loudnessRange: lra,
            maxTruePeakLevel: truePeakDBTP,
            maxMomentaryLoudness: context.hasMomentary ? rint(100 * context.maxMomentary) / 100 : .nan,
            maxShortTermLoudness: context.hasShortTerm ? rint(100 * context.maxShortTerm) / 100 : .nan
        )
    }
}
