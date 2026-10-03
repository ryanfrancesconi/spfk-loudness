// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-loudness

import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

@Suite(.tags(.file))
struct LoudnessGatingBlocksTests {
    private let resources = TestBundleResources.shared

    /// The captured blocks reproduce libebur128's own integrated value, looped files included.
    @Test(arguments: [
        TestBundleResources.shared.tabla_wav,
        TestBundleResources.shared.tabla_mp3,
        TestBundleResources.shared.tabla_6_channel,
        TestBundleResources.shared.cowbell_wav,
        TestBundleResources.shared.pink_noise,
    ])
    func blocksReproduceTheIntegratedValue(url: URL) throws {
        let measurement = try LoudnessAnalyzer.measure(url: url, minimumDuration: 5)

        #expect(measurement.description.loudnessIntegrated != nil)
        #expect(LoudnessGatingBlocks.integratedLoudness(of: [measurement.gatingBlocks]) == measurement.description.loudnessIntegrated)
    }

    @Test func aFileTwiceMeasuresAsItself() throws {
        let measurement = try LoudnessAnalyzer.measure(url: resources.tabla_wav, minimumDuration: 5)

        #expect(LoudnessGatingBlocks.integratedLoudness(of: [measurement.gatingBlocks, measurement.gatingBlocks]) == measurement.description.loudnessIntegrated)
    }

    /// Reference: ffmpeg's `ebur128` over the two files concatenated (tabla resampled to 44.1 kHz)
    /// reads −5.3 LUFS. Tabla's blocks fall below the joint relative gate, so averaging the two
    /// files' results would be about 9 LU too quiet.
    @Test func filesAreGatedTogether() throws {
        let tabla = try LoudnessAnalyzer.measure(url: resources.tabla_wav, minimumDuration: 5)
        let noise = try LoudnessAnalyzer.measure(url: resources.pink_noise, minimumDuration: 5)

        let album = try #require(LoudnessGatingBlocks.integratedLoudness(of: [tabla.gatingBlocks, noise.gatingBlocks]))

        #expect(abs(album - -5.3) < 0.1)
    }

    @Test func nothingToGateIsNil() {
        #expect(LoudnessGatingBlocks.integratedLoudness(of: [LoudnessGatingBlocks()]) == nil)
        #expect(LoudnessGatingBlocks.integratedLoudness(of: [LoudnessGatingBlocks]()) == nil)
    }
}
