// Copyright Ryan Francesconi. All Rights Reserved.

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

@Suite(.tags(.file))
final class LoudnessCancellationTests: TestCaseModel {
    @Test("analyze throws CancellationError on a later poll, not only the first")
    func analyzeHonorsCancellation() throws {
        let url = TestBundleResources.shared.tabla_wav

        // Looping the fixture guarantees several decode iterations whatever its own length,
        // so firing on the third poll proves the check runs per iteration rather than once.
        let minimumDuration = try AVAudioFile(forReading: url).duration * 4
        let counter = CallCounter()

        #expect(throws: CancellationError.self) {
            try LoudnessAnalyzer.analyze(
                url: url,
                minimumDuration: minimumDuration,
                isCancelled: { counter.increment() >= 3 }
            )
        }

        #expect(counter.value == 3)
    }

    @Test("analyze completes normally when isCancelled never fires")
    func analyzeCompletesWhenNotCancelled() throws {
        let result = try LoudnessAnalyzer.analyze(
            url: TestBundleResources.shared.tabla_wav,
            minimumDuration: nil,
            isCancelled: { false }
        )
        #expect(result.isValid)
    }

    @Test("NormalizeAnalyzer rethrows CancellationError but swallows an analysis error")
    func normalizeDistinguishesCancellation() async throws {
        // A file Core Audio cannot open is an ordinary analysis failure: unity gain, no throw.
        let missing = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).wav")
        let desc = try await NormalizeAnalyzer.analyze(url: missing, options: NormalizeOptions())
        #expect(desc.isEmpty)

        // A cancelled task must not be reported as a measurement of unity gain.
        let url = TestBundleResources.shared.tabla_wav
        let task = Task {
            try await NormalizeAnalyzer.analyze(url: url, options: NormalizeOptions(mode: .lufs))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

/// Counts how many times the cancellation predicate has been consulted, so a test can fire it
/// after a chosen number of iterations rather than immediately.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
