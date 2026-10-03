// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import AVFAudio
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

/// Serves an `AVAudioFile` through `SequentialPCMSource`, optionally claiming a length it does
/// not have and failing after a number of reads.
private final class AudioFilePCMSource: SequentialPCMSource {
    let file: AVAudioFile
    let totalFrameCount: AVAudioFramePosition
    let failsAfterReads: Int?
    private(set) var reads = 0

    var processingFormat: AVAudioFormat { file.processingFormat }

    init(url: URL, declaredFrameCount: AVAudioFramePosition? = nil, failsAfterReads: Int? = nil) throws {
        file = try AVAudioFile(forReading: url)
        totalFrameCount = declaredFrameCount ?? file.length
        self.failsAfterReads = failsAfterReads
    }

    func readNextChunk(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws -> AVAudioFrameCount {
        reads += 1

        if let failsAfterReads, reads > failsAfterReads {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard file.framePosition < file.length else { return 0 }

        try file.read(into: buffer, frameCount: frameCount)
        return buffer.frameLength
    }
}

@Suite(.tags(.file))
struct LoudnessPCMSourceTests {
    private func expectEqual(_ lhs: LoudnessDescription, _ rhs: LoudnessDescription) {
        #expect(lhs.loudnessIntegrated == rhs.loudnessIntegrated)
        #expect(lhs.loudnessRange == rhs.loudnessRange)
        #expect(lhs.maxTruePeakLevel == rhs.maxTruePeakLevel)
        #expect(lhs.maxMomentaryLoudness == rhs.maxMomentaryLoudness)
        #expect(lhs.maxShortTermLoudness == rhs.maxShortTermLoudness)
    }

    @Test func matchesTheFileReadOfTheSameSamples() throws {
        let url = TestBundleResources.shared.tabla_wav

        let viaFile = try LoudnessAnalyzer.analyze(url: url, minimumDuration: 5)
        let viaSource = try LoudnessAnalyzer.analyze(pcmSource: AudioFilePCMSource(url: url), minimumDuration: 5)

        #expect(viaFile.loudnessIntegrated != nil)
        expectEqual(viaSource, viaFile)
    }

    @Test func loopsAShortSourceAsTheFileReadDoes() throws {
        let url = TestBundleResources.shared.cowbell_wav

        let file = try AVAudioFile(forReading: url)
        #expect(LoudnessAnalyzer.loops(lengthInFrames: file.length, sampleRate: file.processingFormat.sampleRate, minimumDuration: 5))

        let viaFile = try LoudnessAnalyzer.analyze(url: url, minimumDuration: 5)
        let viaSource = try LoudnessAnalyzer.analyze(pcmSource: AudioFilePCMSource(url: url), minimumDuration: 5)

        expectEqual(viaSource, viaFile)
    }

    @Test func aSourceEndingShortOfItsDeclaredLengthIsNotReplayed() throws {
        let url = TestBundleResources.shared.tabla_wav
        let length = try AVAudioFile(forReading: url).length

        let honest = try LoudnessAnalyzer.analyze(pcmSource: AudioFilePCMSource(url: url), minimumDuration: 5)
        let overstated = try LoudnessAnalyzer.analyze(
            pcmSource: AudioFilePCMSource(url: url, declaredFrameCount: length + 48000),
            minimumDuration: 5
        )

        expectEqual(overstated, honest)
    }

    @Test func aSourceOfUnknownLengthIsReadToItsEnd() throws {
        let url = TestBundleResources.shared.tabla_wav

        let known = try LoudnessAnalyzer.analyze(pcmSource: AudioFilePCMSource(url: url))
        let unknown = try LoudnessAnalyzer.analyze(pcmSource: AudioFilePCMSource(url: url, declaredFrameCount: 0))

        expectEqual(unknown, known)
    }

    @Test func rethrowsTheSourcesError() throws {
        let source = try AudioFilePCMSource(url: TestBundleResources.shared.tabla_wav, failsAfterReads: 1)

        #expect(throws: CocoaError.self) {
            try LoudnessAnalyzer.analyze(pcmSource: source)
        }
    }
}
