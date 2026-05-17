// Copyright Ryan Francesconi. All Rights Reserved.

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@Suite(.tags(.file))
final class BufferPeakTests: TestCaseModel {
    @Test func amplitudeIsPositive() async throws {
        let peak = try await BufferPeak(url: TestBundleResources.shared.tabla_wav)
        #expect(peak.amplitude > 0)
    }

    @Test func sampleRateMatchesFile() async throws {
        let url = TestBundleResources.shared.tabla_wav
        let avfile = try AVAudioFile(forReading: url)
        let peak = try await BufferPeak(url: url)
        let sampleRate = try #require(peak.sampleRate)
        #expect(sampleRate == avfile.processingFormat.sampleRate)
    }

    @Test func framePositionWithinFileBounds() async throws {
        let url = TestBundleResources.shared.tabla_wav
        let avfile = try AVAudioFile(forReading: url)
        let peak = try await BufferPeak(url: url)
        #expect(peak.framePosition >= 0)
        #expect(peak.framePosition < Int(avfile.length))
    }

    @Test func timeConsistentWithFramePosition() async throws {
        let peak = try await BufferPeak(url: TestBundleResources.shared.tabla_wav)
        let sampleRate = try #require(peak.sampleRate)
        let time = try #require(peak.time)
        #expect(abs(time - Double(peak.framePosition) / sampleRate) < 1e-10)
    }

    @Test func sixChannelFile() async throws {
        let peak = try await BufferPeak(url: TestBundleResources.shared.tabla_6_channel)
        #expect(peak.amplitude > 0)
        #expect(peak.sampleRate != nil)
    }

    @Test func cancellationPropagates() async throws {
        let task = Task {
            _ = try await BufferPeak(url: TestBundleResources.shared.tabla_wav)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }
}
