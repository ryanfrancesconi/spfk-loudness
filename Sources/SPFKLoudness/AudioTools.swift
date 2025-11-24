// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/SPFKLoudness

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKUtils

/// For both SoundClassification and Loudness analysis, sometimes the source audio is too short.
/// In this case it works to created a looped version of it so that the analysis windows have more time.
public enum AudioTools {
    public static func createLoopedAudio(input: URL, minimumDuration: TimeInterval) async throws -> URL {
        guard input.exists else {
            throw NSError(description: "\(input.path) is missing")
        }

        let tmpname = input.deletingPathExtension().lastPathComponent + "_\(Entropy.uniqueId)"
        let tmpfile = input.deletingLastPathComponent().appendingPathComponent(tmpname)

        let output = try await createLoopedAudio(input: input, output: tmpfile, minimumDuration: minimumDuration)

        return output
    }

    public static func createLoopedAudio(input: URL, output: URL, minimumDuration: TimeInterval) async throws -> URL {
        guard input.exists else {
            throw NSError(description: "\(input.path) is missing")
        }

        guard input != output else {
            throw NSError(description: "Input shoud be different than the output")
        }

        let avFile = try AVAudioFile(forReading: input)
        var tmpfile: URL?
        let duration = avFile.duration

        guard duration * 2 < minimumDuration else {
            throw NSError(description: "input duration is too long (\(duration)) sec and doesn't make sense to loop. VS minimumDuration \(minimumDuration) sec")
        }

        guard let buffer = try AVAudioPCMBuffer(url: input) else {
            throw NSError(description: "Failed to read audio data into buffer")
        }

        let numberOfDuplicates = (minimumDuration / duration).int + 1

        let duplicatedBuffer = try buffer.loop(numberOfDuplicates: numberOfDuplicates)

        try duplicatedBuffer.write(to: output)

        tmpfile = output

        guard let tmpfile, tmpfile.exists else {
            throw NSError(description: "Failed to create temp file")
        }

        return tmpfile
    }
}
