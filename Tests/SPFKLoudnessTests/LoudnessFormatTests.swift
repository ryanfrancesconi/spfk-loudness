import Foundation
import Numerics
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

@Suite(.tags(.file))
final class LoudnessFormatTests: BinTestCase {
    // MARK: - Multi-format consistency

    @Test("tabla in different containers produces consistent integrated loudness")
    func multiFormatConsistency() async throws {
        let resources = TestBundleResources.shared

        // Same audio content in different containers
        let formats: [(URL, String)] = [
            (resources.tabla_wav, "WAV"),
            (resources.tabla_aif, "AIF"),
            (resources.tabla_flac, "FLAC"),
            (resources.tabla_m4a, "M4A"),
            (resources.tabla_mp4, "MP4"),
        ]

        let reference = try await LoudnessDescription(parsing: resources.tabla_wav)
        let refLUFS = try #require(reference.loudnessIntegrated)

        for (url, label) in formats {
            let loudness = try await LoudnessDescription(parsing: url)
            let lufs = try #require(loudness.loudnessIntegrated,
                                    "loudnessIntegrated is nil for \(label)")

            // Lossy encoding may shift loudness slightly, allow 0.5 LUFS tolerance
            #expect(
                lufs.isApproximatelyEqual(to: refLUFS, absoluteTolerance: 0.5),
                "\(label) integrated loudness \(lufs) differs from WAV \(refLUFS) by more than 0.5 LUFS"
            )
        }
    }

    @Test("lossy formats produce valid loudness")
    func lossyFormats() async throws {
        let resources = TestBundleResources.shared

        let lossyURLs: [(URL, String)] = [
            (resources.tabla_mp3, "MP3"),
            (resources.tabla_aac, "AAC"),
        ]

        for (url, label) in lossyURLs {
            let loudness = try await LoudnessDescription(parsing: url)
            #expect(loudness.isValid, "\(label) should produce valid loudness")
            #expect(loudness.loudnessIntegrated != nil, "\(label) should have integrated loudness")
        }
    }

    // MARK: - Short file full metrics

    @Test("short file produces all five metrics")
    func shortFileAllMetrics() async throws {
        let url = TestBundleResources.shared.cowbell_wav
        let loudness = try await LoudnessDescription(parsing: url)

        #expect(loudness.isValid)
        #expect(loudness.loudnessIntegrated == -29.52)
        #expect(loudness.loudnessRange != nil)
        #expect(loudness.maxTruePeakLevel != nil)
        #expect(loudness.maxMomentaryLoudness != nil)
        #expect(loudness.maxShortTermLoudness != nil)
    }

    // MARK: - Pink noise reference

    @Test("pink noise loudness measurement")
    func pinkNoiseLoudness() async throws {
        let url = TestBundleResources.shared.pink_noise
        let loudness = try await LoudnessDescription(parsing: url)

        #expect(loudness.isValid)

        let lufs = try #require(loudness.loudnessIntegrated)

        // Pink noise should have a measurable, negative LUFS value
        #expect(lufs < 0, "Pink noise should have negative LUFS")
        #expect(lufs > -70, "Pink noise should not be near silence")

        // Pink noise has low dynamic range
        if let range = loudness.loudnessRange {
            #expect(range < 10, "Pink noise should have low loudness range")
        }
    }

    // MARK: - String value format

    @Test("stringValue contains expected format markers")
    func stringValueFormat() async throws {
        let url = TestBundleResources.shared.tabla_wav
        let loudness = try await LoudnessDescription(parsing: url)

        let sv = loudness.stringValue

        #expect(sv.contains("LUFS"))
        #expect(sv.contains("dB"))
        #expect(sv.contains("LRA"))
        #expect(sv.contains("I "))
        #expect(sv.contains("TP "))
    }

    @Test("audioCases all produce non-empty stringValue")
    func audioCasesStringValue() async throws {
        for url in TestBundleResources.shared.audioCases {
            let loudness = try await LoudnessDescription(parsing: url)
            let sv = loudness.stringValue
            #expect(!sv.isEmpty, "\(url.lastPathComponent) produced empty stringValue")
            #expect(sv.contains("LUFS"), "\(url.lastPathComponent) stringValue missing LUFS")
        }
    }

    // MARK: - Validation

    @Test("invalid file produces invalid loudness description")
    func invalidFileValidation() async throws {
        let url = TestBundleResources.shared.no_data_chunk
        let loudness = try await LoudnessDescription(parsing: url)

        #expect(!loudness.isValid)

        // All values should be nil after validation
        #expect(loudness.loudnessIntegrated == nil)
        #expect(loudness.maxTruePeakLevel == nil)
        #expect(loudness.maxMomentaryLoudness == nil)
        #expect(loudness.maxShortTermLoudness == nil)
    }

    @Test("valid measurement has all metrics within valid range")
    func metricsWithinValidRange() async throws {
        let url = TestBundleResources.shared.tabla_wav
        let loudness = try await LoudnessDescription(parsing: url)

        if let v = loudness.loudnessIntegrated {
            #expect((-99.99 ... 99.99).contains(v), "loudnessIntegrated out of valid range")
        }
        if let v = loudness.loudnessRange {
            #expect((-99.99 ... 99.99).contains(v), "loudnessRange out of valid range")
        }
        if let v = loudness.maxTruePeakLevel {
            #expect((-99.99 ... 99.99).contains(v), "maxTruePeakLevel out of valid range")
        }
        if let v = loudness.maxMomentaryLoudness {
            #expect((-99.99 ... 99.99).contains(v), "maxMomentaryLoudness out of valid range")
        }
        if let v = loudness.maxShortTermLoudness {
            #expect((-99.99 ... 99.99).contains(v), "maxShortTermLoudness out of valid range")
        }
    }

    // MARK: - 6-channel audio

    @Test("6-channel audio produces valid loudness")
    func multiChannelLoudness() async throws {
        let url = TestBundleResources.shared.tabla_6_channel
        let loudness = try await LoudnessDescription(parsing: url)

        #expect(loudness.isValid)
        #expect(loudness.loudnessIntegrated != nil)
    }
}
