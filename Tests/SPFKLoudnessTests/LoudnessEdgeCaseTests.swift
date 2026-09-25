import Foundation
import Numerics
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

// MARK: - Error Handling

@Suite(.tags(.file))
final class LoudnessErrorTests: BinTestCase {
    /// As this test is writing an actual file, Make Suite serialized
    @Test("non-audio file produces invalid result or throws")
    func nonAudioFile() async throws {
        let textFile = bin.appendingPathComponent("not_audio.wav")
        try "This is not audio data".write(to: textFile, atomically: true, encoding: .utf8)

        do {
            let loudness = try await LoudnessDescription(parsing: textFile)
            #expect(!loudness.isValid)
        } catch {
            // Throwing is also acceptable
        }
    }

    @Test("non-existent file path throws")
    func nonExistentFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).wav")
        await #expect(throws: Error.self) {
            try await LoudnessDescription(parsing: url)
        }
    }

    @Test("LoudnessAnalyzer throws for non-existent file")
    func analyzerThrowsForMissingFile() throws {
        let url = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).wav")
        #expect(throws: Error.self) {
            try LoudnessAnalyzer.analyze(url: url)
        }
    }

    @Test("LoudnessAnalyzer produces valid result for valid file")
    func analyzerSucceedsForValidFile() throws {
        let url = TestBundleResources.shared.tabla_wav
        let result = try LoudnessAnalyzer.analyze(url: url)

        let li = try #require(result.loudnessIntegrated)
        let lra = try #require(result.loudnessRange)
        let maxTP = try #require(result.maxTruePeakLevel)

        #expect(!li.isNaN)
        #expect(!lra.isNaN)
        #expect(!maxTP.isNaN)
    }
}

// MARK: - Additional Format Coverage

@Suite(.tags(.file))
final class LoudnessAdditionalFormatTests: BinTestCase {
    @Test("CAF format produces valid loudness")
    func cafFormat() async throws {
        let url = TestBundleResources.shared.tabla_caf
        let loudness = try await LoudnessDescription(parsing: url)

        #expect(loudness.isValid)

        let lufs = try #require(loudness.loudnessIntegrated)
        // Compare to known tabla WAV value
        #expect(lufs.isApproximatelyEqual(to: -24.13, absoluteTolerance: 0.5))
    }

    @Test("OGG format produces valid loudness")
    func oggFormat() async throws {
        let url = TestBundleResources.shared.tabla_ogg
        let loudness = try await LoudnessDescription(parsing: url)

        #expect(loudness.isValid)
        #expect(loudness.loudnessIntegrated != nil)
    }

    @Test("MP3 without metadata produces valid loudness")
    func mp3NoMetadata() async throws {
        let url = TestBundleResources.shared.mp3_no_metadata
        let loudness = try await LoudnessDescription(parsing: url)

        #expect(loudness.isValid)
        #expect(loudness.loudnessIntegrated != nil)
    }
}
