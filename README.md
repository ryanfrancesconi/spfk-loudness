# SPFKLoudness

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-loudness%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-loudness)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-loudness%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-loudness)

A Swift package for measuring audio loudness according to the [EBU R128](https://tech.ebu.ch/docs/r/r128.pdf) standard. Built on [libebur128](https://github.com/jiixyj/libebur128) with a pure Swift analysis layer using Core Audio for decoding and sample-rate conversion.

Provides integrated loudness (LUFS), loudness range (LU), true peak (dBTP), and momentary/short-term loudness values for any audio format supported by Core Audio.

## Usage

### Analyzing a single file

```swift
import SPFKLoudness

let result = try LoudnessAnalyzer.analyze(url: audioFileURL)

result.loudnessIntegrated    // -24.13 (LUFS)
result.loudnessRange         // 1.43 (LU)
result.maxTruePeakLevel      // -0.07 (dBTP)
result.maxMomentaryLoudness  // -19.51 (LUFS)
result.maxShortTermLoudness  // -22.99 (LUFS)
```

### Handling short files

Files shorter than 2.5 seconds don't provide enough material for a stable integrated loudness measurement. Pass `minimumDuration` to loop the audio in-memory until the target length is reached:

```swift
let result = try LoudnessAnalyzer.analyze(url: shortFileURL, minimumDuration: 5)
```

### Convenience initializer

`LoudnessDescription(parsing:)` wraps the analyzer with a default 5-second minimum duration and validates the result:

```swift
let loudness = try await LoudnessDescription(parsing: audioFileURL)

loudness.isValid      // true if at least one metric is non-nil
loudness.stringValue  // "I -24.1 LUFS, TP -0.1 dB, LRA 1.4 LU, M -19.5 LU, S -23.0 LU"
```

### Averaging across files

```swift
let descriptions = try await files.asyncMap { try await LoudnessDescription(parsing: $0) }
let average = descriptions.average

average.loudnessIntegrated  // arithmetic mean of integrated values
```

## EBU R128 Metrics

| Metric | Property | Unit | Description |
|--------|----------|------|-------------|
| Integrated Loudness | `loudnessIntegrated` | LUFS | Program loudness over the entire file, with gating |
| Loudness Range | `loudnessRange` | LU | Dynamic range per EBU Tech 3342 |
| True Peak | `maxTruePeakLevel` | dBTP | Maximum inter-sample peak level |
| Max Momentary | `maxMomentaryLoudness` | LUFS | Highest 400 ms loudness window |
| Max Short-Term | `maxShortTermLoudness` | LUFS | Highest 3 s loudness window |

## Architecture

```
SPFKLoudness (Swift)
  ├── LoudnessAnalyzer.swift            — Public API: analyze(url:minimumDuration:)
  ├── LoudnessDescription+Init.swift    — Convenience async init with validation
  └── Internal/
      ├── CallbackContext.swift          — Mutable state for the AudioConverter callback
      └── AudioConverterCallback.swift   — @convention(c) callback: reads audio, feeds ebur128

SPFKLoudnessC (C)
  └── r128x/
      └── ebur128.c                     — libebur128 (EBU R128 / ITU BS.1770-4)
```

### Processing Pipeline

1. **File decoding** — `ExtAudioFile` opens the file and delivers 32-bit float interleaved PCM
2. **Oversampling** — `AudioConverter` upsamples for true peak detection (4x for ≤48 kHz, 2x for ≤96 kHz, 1x above)
3. **Loudness measurement** — Decoded frames are fed to libebur128 in 100 ms chunks; momentary and short-term maxima are tracked per chunk
4. **True peak detection** — Oversampled output is scanned with `vDSP_maxmgv` for vectorized max-magnitude detection
5. **Looping** (optional) — If the file is shorter than half the `minimumDuration`, the callback seeks back to the start on EOF and continues feeding frames
6. **Validation** — Results outside the representable range (±99.99) are set to nil

## Supported Formats

Any audio format readable by Core Audio's `ExtAudioFile`, including WAV, AIF, FLAC, M4A, MP4, MP3, AAC, CAF, and OGG.

## Dependencies

| Package | Purpose |
|---------|---------|
| [spfk-audio-base](https://github.com/ryanfrancesconi/spfk-audio-base) | `LoudnessDescription` type |
| [spfk-testing](https://github.com/ryanfrancesconi/spfk-testing) | Test audio resources (test target only) |

## Requirements

- macOS 12+ / iOS 15+
- Swift 6.2+

## About

Spongefork (SPFK) is the personal software projects of [Ryan Francesconi](https://github.com/ryanfrancesconi). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2016 to 2025 he was the lead macOS developer at [Audio Design Desk](https://add.app).
