import AVFoundation
import Numerics
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

@Suite(.tags(.file))
final class LoudnessTests: TestCaseModel {
    @Test func measureLoudness() async throws {
        let url = TestBundleResources.shared.tabla_wav

        let loudness = try await LoudnessDescription(parsing: url)

        let range = try #require(loudness.loudnessRange)

        #expect(loudness.loudnessIntegrated == -24.13)
        #expect(range == 1.43)
        #expect(loudness.maxTruePeakLevel == -0.07)
        #expect(loudness.maxMomentaryLoudness == -19.51)
        #expect(loudness.maxShortTermLoudness == -22.99)
    }

    @Test func measureLoudnessShortFile() async throws {
        let url = TestBundleResources.shared.cowbell_wav

        let loudness = try await LoudnessDescription(parsing: url)

        #expect(loudness.loudnessIntegrated == -29.52)
    }

    @Test func averageLoudness() async throws {
        let urls = [
            TestBundleResources.shared.mp3_id3, TestBundleResources.shared.tabla_wav,
            TestBundleResources.shared.cowbell_wav,
        ]

        var values = [LoudnessDescription]()

        for url in urls {
            guard let value = try? await LoudnessDescription(parsing: url) else { continue }

            values.append(value)
        }

        let lufs = try #require(values.average.loudnessIntegrated)

        #expect(
            lufs.isApproximatelyEqual(to: -25.29, relativeTolerance: 0.001)
        )
    }
}
