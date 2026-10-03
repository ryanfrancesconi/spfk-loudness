// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AVFAudio
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

/// `tabla_6_channel.wav` declares 5.1 in WAV order (L R C LFE Ls Rs, per `afinfo`).
@Suite(.tags(.file))
final class LoudnessChannelLayoutTests: BinTestCase {
    private var source: URL { TestBundleResources.shared.tabla_6_channel }

    /// WAV order → film order (L C R Ls Rs LFE).
    private let filmOrder = [0, 2, 1, 4, 5, 3]

    /// Writes the fixture's samples reordered to film order, declaring `MPEG_5_1_C` so the order is
    /// stated rather than implied.
    private func writeFilmOrderCopy() throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let frames = AVAudioFrameCount(input.length)

        let wavBuffer = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames))
        try input.read(into: wavBuffer)

        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_C))
        let filmFormat = AVAudioFormat(standardFormatWithSampleRate: input.processingFormat.sampleRate, channelLayout: layout)
        let filmBuffer = try #require(AVAudioPCMBuffer(pcmFormat: filmFormat, frameCapacity: frames))
        filmBuffer.frameLength = wavBuffer.frameLength

        let from = try #require(wavBuffer.floatChannelData)
        let to = try #require(filmBuffer.floatChannelData)

        for (filmChannel, wavChannel) in filmOrder.enumerated() {
            to[filmChannel].update(from: from[wavChannel], count: Int(frames))
        }

        let url = bin.appendingPathComponent("tabla_film_order.caf")
        let output = try AVAudioFile(forWriting: url, settings: filmFormat.settings)
        try output.write(from: filmBuffer)

        return url
    }

    @Test func wavOrderIsReadFromTheFile() throws {
        let measurement = try LoudnessAnalyzer.measure(url: source, minimumDuration: 5)

        #expect(measurement.usesDeclaredChannelLayout)
    }

    @Test func filmOrderMeasuresAsTheOriginal() throws {
        let original = try LoudnessAnalyzer.measure(url: source, minimumDuration: 5)
        let film = try LoudnessAnalyzer.measure(url: writeFilmOrderCopy(), minimumDuration: 5)

        #expect(film.usesDeclaredChannelLayout)
        #expect(film.description.loudnessIntegrated == original.description.loudnessIntegrated)
    }

    @Test func anUnweightedLabelLeavesTheDefault() {
        #expect(ChannelMap.ebur128Channels(for: [kAudioChannelLabel_Ambisonic_W, kAudioChannelLabel_Ambisonic_X]) == nil)
        #expect(ChannelMap.ebur128Channels(for: [kAudioChannelLabel_Left, kAudioChannelLabel_Right]) != nil)
    }
}
