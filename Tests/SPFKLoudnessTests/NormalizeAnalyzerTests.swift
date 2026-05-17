// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

@Suite(.tags(.file))
final class NormalizeAnalyzerTests: TestCaseModel {
    // MARK: - LUFS mode

    @Test func lufsMode_producesPositiveGain() async {
        let options = NormalizeOptions(mode: .lufs, ceilingEnabled: false, maximumGainEnabled: false)
        let desc = await NormalizeAnalyzer.analyze(url: TestBundleResources.shared.tabla_wav, options: options)
        #expect(desc.gain > 0)
    }

    @Test func lufsMode_measuredLUFSPopulated() async {
        let options = NormalizeOptions(mode: .lufs, ceilingEnabled: false, maximumGainEnabled: false)
        let desc = await NormalizeAnalyzer.analyze(url: TestBundleResources.shared.tabla_wav, options: options)
        #expect(desc.measuredLUFS != nil)
    }

    @Test func lufsMode_maximumGainClampsBoost() async {
        // tabla_wav is quiet (-24 LUFS); targeting -14 LUFS would normally boost it.
        // With maximumGaindB = 0 and ceiling disabled the gain must be clamped to unity.
        let options = NormalizeOptions(
            mode: .lufs,
            targetLUFS: -14,
            ceilingEnabled: false,
            maximumGainEnabled: true,
            maximumGaindB: 0
        )
        let desc = await NormalizeAnalyzer.analyze(url: TestBundleResources.shared.tabla_wav, options: options)
        #expect(desc.isEmpty)
    }

    @Test func lufsMode_ceilingConstraintReducesGain() async {
        let url = TestBundleResources.shared.tabla_wav
        let uncapped = await NormalizeAnalyzer.analyze(url: url, options: NormalizeOptions(
            mode: .lufs, targetLUFS: -14, ceilingEnabled: false, maximumGainEnabled: false
        ))
        let capped = await NormalizeAnalyzer.analyze(url: url, options: NormalizeOptions(
            mode: .lufs, targetLUFS: -14, ceilingEnabled: true, ceilingdBTP: -1.0, maximumGainEnabled: false
        ))
        // tabla_wav true peak (-0.07 dBTP) + uncapped boost would exceed the ceiling,
        // so the ceiling path must reduce gain below the uncapped value.
        #expect(capped.gain < uncapped.gain)
    }

    // MARK: - Peak mode

    @Test func peakMode_producesPositiveGain() async {
        let options = NormalizeOptions(mode: .peak, maximumGainEnabled: false)
        let desc = await NormalizeAnalyzer.analyze(url: TestBundleResources.shared.tabla_wav, options: options)
        #expect(desc.gain > 0)
    }

    @Test func peakMode_measuredPeakPopulated() async {
        let options = NormalizeOptions(mode: .peak, maximumGainEnabled: false)
        let desc = await NormalizeAnalyzer.analyze(url: TestBundleResources.shared.tabla_wav, options: options)
        #expect(desc.measuredPeakdBFS != nil)
    }

    @Test func peakMode_maximumGainClampsBoost() async {
        // Targeting 0 dBFS would boost a quiet file; clamping to 0 dB max → unity.
        let options = NormalizeOptions(
            mode: .peak,
            targetPeakdBFS: 0,
            maximumGainEnabled: true,
            maximumGaindB: 0
        )
        let desc = await NormalizeAnalyzer.analyze(url: TestBundleResources.shared.tabla_wav, options: options)
        #expect(desc.isEmpty)
    }

    // MARK: - Error handling

    @Test func invalidUrl_returnsUnityGain() async {
        let url = URL(fileURLWithPath: "/nonexistent/audio.wav")
        let desc = await NormalizeAnalyzer.analyze(url: url, options: NormalizeOptions())
        #expect(desc.isEmpty)
    }
}
