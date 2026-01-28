import AVFoundation
import Numerics
import SPFKBase
@testable import SPFKLoudness
import SPFKLoudnessC
import SPFKTesting
import Testing

@Suite(.tags(.file))
final class LoudnessTests: BinTestCase {
    @Test func testMeasureLoudness() async throws {
        let url = TestBundleResources.shared.tabla_wav

        let loudness = try await LoudnessDescription(url: url)

        let range = try #require(loudness.loudnessRange)

        #expect(loudness.loudnessValue == -24.13)
        #expect(range == 1.43)
        #expect(loudness.maxTruePeakLevel == -0.07)
        #expect(loudness.maxMomentaryLoudness == -19.51)
        #expect(loudness.maxShortTermLoudness == -22.99)
    }

    @Test func testMeasureLoudnessShortFile() async throws {
        let url = TestBundleResources.shared.cowbell_wav

        let loudness = try await LoudnessDescription(url: url)

        #expect(loudness.loudnessValue == -29.5)
    }

    @Test func testAverageLoudness() async throws {
        let targetLevel: Double = -23

        let urls = [TestBundleResources.shared.mp3_id3, TestBundleResources.shared.tabla_wav, TestBundleResources.shared.cowbell_wav]

        var values = [LoudnessDescription]()

        for url in urls {
            guard let value = try? await LoudnessDescription(url: url) else { continue }

            values.append(value)

            Log.debug("Change to target is", targetLevel - (value.loudnessValue ?? 0))
        }

        let lufs = try #require(LoudnessDescription.averageLoudness(from: values).loudnessValue)

        Log.debug("🔊 values:", values)
        Log.debug("🔊 average:", lufs)

        #expect(
            lufs.isApproximatelyEqual(to: -25.26, relativeTolerance: 0.001)
        )
    }
}
