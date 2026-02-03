import AVFoundation
import Numerics
import SPFKAudioBase
import SPFKBase
import SPFKLoudnessC
import SPFKTesting
import Testing

@testable import SPFKLoudness

@Suite(.tags(.file))
final class LoudnessTests: BinTestCase {
    @Test func measureLoudness() async throws {
        let url = TestBundleResources.shared.tabla_wav

        let loudness = try await LoudnessDescription(parsing: url)

        let range = try #require(loudness.loudnessRange)

        #expect(loudness.loudnessValue == -24.13)
        #expect(range == 1.43)
        #expect(loudness.maxTruePeakLevel == -0.07)
        #expect(loudness.maxMomentaryLoudness == -19.51)
        #expect(loudness.maxShortTermLoudness == -22.99)
    }

    @Test func measureLoudnessShortFile() async throws {
        let url = TestBundleResources.shared.cowbell_wav

        let loudness = try await LoudnessDescription(parsing: url)

        #expect(loudness.loudnessValue == -29.52)
    }

    @Test func testAverageLoudness() async throws {
        let targetLevel: Float64 = -23

        let urls = [
            TestBundleResources.shared.mp3_id3, TestBundleResources.shared.tabla_wav,
            TestBundleResources.shared.cowbell_wav,
        ]

        var values = [LoudnessDescription]()

        for url in urls {
            guard let value = try? await LoudnessDescription(parsing: url) else { continue }

            values.append(value)

            Log.debug("Change to target is", targetLevel - (value.loudnessValue ?? 0))
        }

        let lufs = try #require(LoudnessDescription.averageLoudness(from: values).loudnessValue)

        Log.debug("🔊 values:", values)
        Log.debug("🔊 average:", lufs)

        #expect(
            lufs.isApproximatelyEqual(to: -25.29, relativeTolerance: 0.001)
        )
    }
}
