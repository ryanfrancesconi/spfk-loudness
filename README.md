# SPFKLoudness

[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-loudness)](https://github.com/ryanfrancesconi/spfk-loudness/tags)
[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-loudness%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-loudness)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-loudness%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-loudness)

Loudness measurement to the [EBU R128](https://tech.ebu.ch/docs/r/r128.pdf) standard for audio
files: integrated loudness, loudness range, true peak, and maximum momentary and short-term
loudness. Measurement uses the vendored [libebur128](https://github.com/jiixyj/libebur128) (MIT),
with Core Audio decoding and oversampling, so any format Core Audio reads can be measured.

## Features

- Measure a file with `LoudnessDescription(parsing:)`
- Measure decoded audio from a `SequentialPCMSource`, for containers Core Audio cannot open or
  tracks other than the first
- Measure a set of files as one program, such as an album, with `LoudnessGatingBlocks`
- Compute the gain that brings a file to a LUFS or peak target with `NormalizeAnalyzer`, optionally
  limited by a true-peak ceiling and a maximum gain
- Channels are weighted by the file's declared channel layout

## Usage

```swift
import SPFKAudioBase
import SPFKLoudness

let loudness = try await LoudnessDescription(parsing: url)
// loudness.loudnessIntegrated (LUFS), loudness.maxTruePeakLevel (dBTP), ...
```

```swift
let tracks = try urls.map { try LoudnessAnalyzer.measure(url: $0, minimumDuration: 5) }
let albumLUFS = LoudnessGatingBlocks.integratedLoudness(of: tracks.map(\.gatingBlocks))
```

```swift
let normalize = try await NormalizeAnalyzer.analyze(url: url, options: NormalizeOptions(mode: .lufs))
// normalize.gain is a linear multiplier
```

## Notes

- Decoding is synchronous. The `async` entry points do not suspend, so call them from a task off
  the main actor. Cancelling the task stops the decode.
- Values outside the representable range are returned as `nil`.
- Files shorter than 2.5 seconds are looped in memory so the integrated measurement is stable.
- With no channel layout declared, WAV channel order is assumed.
- `NormalizeAnalyzer` throws when a file cannot be read. A silent file returns unity gain.
- `LoudnessDescription` is declared in spfk-audio-base, so code that only stores or displays
  loudness does not need this package.

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
