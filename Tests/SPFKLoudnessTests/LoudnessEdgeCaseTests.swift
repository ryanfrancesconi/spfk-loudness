import Foundation
import Numerics
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKLoudness

// MARK: - Error Handling

@Suite(.serialized, .tags(.file))
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

// MARK: - Validation Edge Cases

@Suite(.tags(.file))
final class LoudnessValidationTests: TestCaseModel {
    @Test("validated() clears out-of-range values")
    func validatedClearsOutOfRange() {
        let desc = LoudnessDescription(
            loudnessIntegrated: -200,
            loudnessRange: 500,
            maxTruePeakLevel: 327.67,
            maxMomentaryLoudness: -100,
            maxShortTermLoudness: 100
        ).validated()

        #expect(desc.loudnessIntegrated == nil)
        #expect(desc.loudnessRange == nil)
        #expect(desc.maxTruePeakLevel == nil)
        #expect(desc.maxMomentaryLoudness == nil)
        #expect(desc.maxShortTermLoudness == nil)
        #expect(!desc.isValid)
    }

    @Test("validated() preserves in-range values")
    func validatedPreservesInRange() {
        let desc = LoudnessDescription(
            loudnessIntegrated: -24.0,
            loudnessRange: 5.0,
            maxTruePeakLevel: -0.1,
            maxMomentaryLoudness: -20.0,
            maxShortTermLoudness: -22.0
        ).validated()

        #expect(desc.loudnessIntegrated == -24.0)
        #expect(desc.loudnessRange == 5.0)
        #expect(desc.maxTruePeakLevel == -0.1)
        #expect(desc.maxMomentaryLoudness == -20.0)
        #expect(desc.maxShortTermLoudness == -22.0)
        #expect(desc.isValid)
    }

    @Test("validated() handles boundary values")
    func validatedBoundaryValues() {
        let atBoundary = LoudnessDescription(
            loudnessIntegrated: -99.99,
            loudnessRange: 99.99,
            maxTruePeakLevel: 0,
            maxMomentaryLoudness: -99.99,
            maxShortTermLoudness: 99.99
        ).validated()

        #expect(atBoundary.loudnessIntegrated == -99.99)
        #expect(atBoundary.loudnessRange == 99.99)
        #expect(atBoundary.maxTruePeakLevel == 0)
        #expect(atBoundary.maxMomentaryLoudness == -99.99)
        #expect(atBoundary.maxShortTermLoudness == 99.99)
    }

    @Test("validated() clears just-outside-boundary values")
    func validatedJustOutsideBoundary() {
        let justOutside = LoudnessDescription(
            loudnessIntegrated: -100.0,
            loudnessRange: 100.0
        ).validated()

        #expect(justOutside.loudnessIntegrated == nil)
        #expect(justOutside.loudnessRange == nil)
    }

    @Test("isValid returns true with only one non-nil metric")
    func isValidPartialMetrics() {
        let integratedOnly = LoudnessDescription(loudnessIntegrated: -24.0)
        #expect(integratedOnly.isValid)

        let truePeakOnly = LoudnessDescription(maxTruePeakLevel: -1.0)
        #expect(truePeakOnly.isValid)

        let momentaryOnly = LoudnessDescription(maxMomentaryLoudness: -20.0)
        #expect(momentaryOnly.isValid)

        let shortTermOnly = LoudnessDescription(maxShortTermLoudness: -22.0)
        #expect(shortTermOnly.isValid)
    }

    @Test("isValid returns false when all metrics are nil")
    func isValidAllNil() {
        let empty = LoudnessDescription()
        #expect(!empty.isValid)
    }

    @Test("isValid returns false when only loudnessRange is set")
    func isValidOnlyRange() {
        // loudnessRange alone doesn't make it valid per the implementation
        let rangeOnly = LoudnessDescription(loudnessRange: 5.0)
        #expect(!rangeOnly.isValid)
    }

    @Test("0x7FFF sentinel value is cleared by validation")
    func sentinelValueCleared() {
        let sentinel: Float64 = 327.67 // 0x7FFF / 100
        let desc = LoudnessDescription(
            loudnessIntegrated: sentinel,
            loudnessRange: sentinel,
            maxTruePeakLevel: Float32(sentinel),
            maxMomentaryLoudness: sentinel,
            maxShortTermLoudness: sentinel
        ).validated()

        #expect(!desc.isValid)
    }
}

// MARK: - Codable

@Suite(.tags(.file))
struct LoudnessDescriptionCodableTests {
    @Test("JSON round-trip preserves all values")
    func jsonRoundTrip() throws {
        let original = LoudnessDescription(
            loudnessIntegrated: -24.13,
            loudnessRange: 1.43,
            maxTruePeakLevel: -0.07,
            maxMomentaryLoudness: -19.51,
            maxShortTermLoudness: -22.99
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LoudnessDescription.self, from: data)

        #expect(decoded.loudnessIntegrated == original.loudnessIntegrated)
        #expect(decoded.loudnessRange == original.loudnessRange)
        #expect(decoded.maxTruePeakLevel == original.maxTruePeakLevel)
        #expect(decoded.maxMomentaryLoudness == original.maxMomentaryLoudness)
        #expect(decoded.maxShortTermLoudness == original.maxShortTermLoudness)
    }

    @Test("JSON round-trip preserves nil values")
    func jsonRoundTripNils() throws {
        let original = LoudnessDescription(
            loudnessIntegrated: -24.0,
            loudnessRange: nil,
            maxTruePeakLevel: nil,
            maxMomentaryLoudness: nil,
            maxShortTermLoudness: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LoudnessDescription.self, from: data)

        #expect(decoded.loudnessIntegrated == -24.0)
        #expect(decoded.loudnessRange == nil)
        #expect(decoded.maxTruePeakLevel == nil)
        #expect(decoded.maxMomentaryLoudness == nil)
        #expect(decoded.maxShortTermLoudness == nil)
    }

    @Test("decodes from partial JSON")
    func decodesPartialJSON() throws {
        let json = #"{"loudnessIntegrated": -14.5}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(LoudnessDescription.self, from: data)

        #expect(decoded.loudnessIntegrated == -14.5)
        #expect(decoded.loudnessRange == nil)
        #expect(decoded.maxTruePeakLevel == nil)
    }

    @Test("decodes from empty JSON object")
    func decodesEmptyJSON() throws {
        let json = "{}"
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(LoudnessDescription.self, from: data)

        #expect(!decoded.isValid)
    }
}

// MARK: - Averaging Edge Cases

@Suite(.tags(.file))
struct LoudnessAveragingTests {
    @Test("empty array average is invalid")
    func emptyArrayAverage() {
        let avg = [LoudnessDescription]().average
        #expect(!avg.isValid)
    }

    @Test("single item average equals that item")
    func singleItemAverage() {
        let desc = LoudnessDescription(
            loudnessIntegrated: -24.0,
            loudnessRange: 5.0,
            maxTruePeakLevel: -0.1
        )

        let avg = [desc].average

        #expect(avg.loudnessIntegrated == -24.0)
        #expect(avg.loudnessRange == 5.0)
        #expect(avg.maxTruePeakLevel == -0.1)
    }

    @Test("average of all-invalid descriptions is invalid")
    func allInvalidAverage() {
        let invalid1 = LoudnessDescription() // all nil
        let invalid2 = LoudnessDescription(loudnessRange: 5.0) // only range, isValid=false

        let avg = [invalid1, invalid2].average
        #expect(!avg.isValid)
    }

    @Test("average skips nil metrics per-property")
    func averageSkipsNilMetrics() {
        let a = LoudnessDescription(
            loudnessIntegrated: -20.0,
            maxTruePeakLevel: -1.0
        )
        let b = LoudnessDescription(
            loudnessIntegrated: -30.0,
            maxTruePeakLevel: nil
        )

        let avg = [a, b].average

        // Both have integrated, so average both
        #expect(avg.loudnessIntegrated?.isApproximatelyEqual(to: -25.0, absoluteTolerance: 0.01) == true)
        // Only one has truePeak, so average is just that one
        #expect(avg.maxTruePeakLevel == -1.0)
    }

    @Test("average correctly combines two known descriptions")
    func averageTwoKnown() {
        let a = LoudnessDescription(
            loudnessIntegrated: -20.0,
            loudnessRange: 4.0,
            maxTruePeakLevel: -0.5,
            maxMomentaryLoudness: -15.0,
            maxShortTermLoudness: -18.0
        )
        let b = LoudnessDescription(
            loudnessIntegrated: -30.0,
            loudnessRange: 6.0,
            maxTruePeakLevel: -1.5,
            maxMomentaryLoudness: -25.0,
            maxShortTermLoudness: -28.0
        )

        let avg = [a, b].average

        #expect(avg.loudnessIntegrated?.isApproximatelyEqual(to: -25.0, absoluteTolerance: 0.01) == true)
        #expect(avg.loudnessRange?.isApproximatelyEqual(to: 5.0, absoluteTolerance: 0.01) == true)
        #expect(avg.maxTruePeakLevel?.isApproximatelyEqual(to: -1.0, absoluteTolerance: 0.01) == true)
        #expect(avg.maxMomentaryLoudness?.isApproximatelyEqual(to: -20.0, absoluteTolerance: 0.01) == true)
        #expect(avg.maxShortTermLoudness?.isApproximatelyEqual(to: -23.0, absoluteTolerance: 0.01) == true)
    }
}

// MARK: - Comparable and Hashable

@Suite(.tags(.file))
struct LoudnessComparableTests {
    @Test("comparison uses loudnessIntegrated")
    func comparesbyIntegrated() {
        let quieter = LoudnessDescription(loudnessIntegrated: -30.0)
        let louder = LoudnessDescription(loudnessIntegrated: -20.0)

        #expect(quieter < louder)
        #expect(!(louder < quieter))
    }

    @Test("comparison with nil returns false")
    func comparisonWithNil() {
        let valid = LoudnessDescription(loudnessIntegrated: -24.0)
        let nilDesc = LoudnessDescription()

        // Both directions should return false when either is nil
        #expect(!(valid < nilDesc))
        #expect(!(nilDesc < valid))
    }

    @Test("sorting orders by integrated loudness")
    func sortingOrder() {
        let a = LoudnessDescription(loudnessIntegrated: -30.0)
        let b = LoudnessDescription(loudnessIntegrated: -20.0)
        let c = LoudnessDescription(loudnessIntegrated: -25.0)

        let sorted = [a, b, c].sorted()
        #expect(sorted[0].loudnessIntegrated == -30.0)
        #expect(sorted[1].loudnessIntegrated == -25.0)
        #expect(sorted[2].loudnessIntegrated == -20.0)
    }

    @Test("hashable works in sets")
    func hashableInSet() {
        let a = LoudnessDescription(loudnessIntegrated: -24.0, loudnessRange: 5.0)
        let b = LoudnessDescription(loudnessIntegrated: -24.0, loudnessRange: 5.0)
        let c = LoudnessDescription(loudnessIntegrated: -30.0)

        let set: Set<LoudnessDescription> = [a, b, c]
        #expect(set.count == 2)
    }

    @Test("equal descriptions have same hash")
    func equalHashValues() {
        let a = LoudnessDescription(
            loudnessIntegrated: -24.0,
            loudnessRange: 5.0,
            maxTruePeakLevel: -0.1
        )
        let b = LoudnessDescription(
            loudnessIntegrated: -24.0,
            loudnessRange: 5.0,
            maxTruePeakLevel: -0.1
        )

        #expect(a.hashValue == b.hashValue)
    }
}

// MARK: - String Formatting

@Suite(.tags(.file))
struct LoudnessStringValueTests {
    @Test("all-nil description produces N/A values")
    func allNilStringValue() {
        let desc = LoudnessDescription()
        let sv = desc.stringValue

        #expect(sv.contains("I N/A LUFS"))
        #expect(sv.contains("TP N/A dB"))
        #expect(sv.contains("LRA N/A LU"))
        // Momentary and ShortTerm should be omitted when nil
        #expect(!sv.contains("M "))
        #expect(!sv.contains("S "))
    }

    @Test("partial values show N/A only for missing metrics")
    func partialStringValue() {
        let desc = LoudnessDescription(
            loudnessIntegrated: -24.0,
            maxMomentaryLoudness: -19.5
        )
        let sv = desc.stringValue

        #expect(sv.contains("I -24.0 LUFS"))
        #expect(sv.contains("TP N/A dB"))
        #expect(sv.contains("LRA N/A LU"))
        #expect(sv.contains("M -19.5 LU"))
        #expect(!sv.contains("S "))
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
