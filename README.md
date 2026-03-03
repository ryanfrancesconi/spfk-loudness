# SPFKLoudness

A Swift package for measuring audio loudness according to the [EBU R128](https://tech.ebu.ch/docs/r/r128.pdf) standard. Built on top of [libebur128](https://github.com/jiixyj/libebur128) via an Objective-C bridge, providing integrated loudness (LUFS), loudness range (LU), true peak (dBTP), and momentary/short-term loudness values.

## Overview

SPFKLoudness provides a single async entry point for loudness analysis:

- **`LoudnessDescription(parsing:)`** — Analyzes an audio file and returns all five EBU R128 metrics. Automatically handles short files by looping audio to meet the minimum 5-second duration required by the standard.

Results are returned via the `LoudnessDescription` struct (defined in SPFKAudioBase), which includes validation, averaging across multiple files, and formatted string output.

## Usage

```swift
// Analyze a single file
let loudness = try await LoudnessDescription(parsing: audioFileURL)

loudness.loudnessIntegrated    // -24.13 (LUFS)
loudness.loudnessRange         // 1.43 (LU)
loudness.maxTruePeakLevel      // -0.07 (dBTP)
loudness.maxMomentaryLoudness  // -19.51 (LUFS)
loudness.maxShortTermLoudness  // -22.99 (LUFS)

loudness.isValid               // true if at least one metric is non-nil
loudness.stringValue           // "I -24.1 LUFS, TP -0.1 dB, LRA 1.4 LU, M -19.5 LU, S -23.0 LU"

// Average loudness across multiple files
let descriptions = [loudness1, loudness2, loudness3]
let average = descriptions.average
average.loudnessIntegrated     // arithmetic mean of integrated values
```

## EBU R128 Metrics

| Metric | Property | Unit | Description |
|--------|----------|------|-------------|
| Integrated Loudness | `loudnessIntegrated` | LUFS | Program loudness over entire file, with gating |
| Loudness Range | `loudnessRange` | LU | Dynamic range (EBU TECH 3342) |
| True Peak | `maxTruePeakLevel` | dBTP | Maximum inter-sample peak level |
| Max Momentary | `maxMomentaryLoudness` | LUFS | Highest 400ms loudness window |
| Max Short-Term | `maxShortTermLoudness` | LUFS | Highest 3s loudness window |

## Architecture

```
SPFKLoudness (Swift)
  └── LoudnessDescription+Init.swift  — Async init: loops short files, calls scanner, validates

SPFKLoudnessC (Objective-C / C)
  ├── LoudnessScanner.m               — ObjC wrapper bridging C functions to Swift
  └── r128x/
      ├── AudioProcessor.c            — Audio file reading via ExtAudioFile + AudioConverter
      └── ebur128.c                   — libebur128 implementation (EBU R128 / ITU BS.1770)
```

### Processing Pipeline

1. **File preparation** — If the audio is shorter than 5 seconds, a looped copy is created to meet EBU R128 minimum duration requirements
2. **Audio reading** — `ExtAudioFile` opens the file and converts to 32-bit float PCM
3. **Oversampling** — `AudioConverter` upsamples for true peak detection (4x for ≤48kHz, 2x for ≤96kHz, 1x for higher)
4. **Loudness calculation** — Audio frames are fed to libebur128 which applies ITU BS.1770 K-weighting filters and computes all metrics
5. **Validation** — Results outside the valid range (-99.99 to 99.99) are set to nil

## Supported Formats

Any audio format readable by Apple's `ExtAudioFile` API, including WAV, AIF, FLAC, M4A, MP4, MP3, AAC, CAF, and OGG.

## Dependencies

| Package | Purpose |
|---------|---------|
| [spfk-audio-base](https://github.com/ryanfrancesconi/spfk-audio-base) | `LoudnessDescription` type, `AudioTools` for file looping |
| [spfk-base](https://github.com/ryanfrancesconi/spfk-base) | Logging, error utilities |
| [spfk-utils](https://github.com/ryanfrancesconi/spfk-utils) | URL and string extensions |
| [spfk-testing](https://github.com/ryanfrancesconi/spfk-testing) | Test audio resources (test target only) |

## Requirements

- macOS 12+ / iOS 15+
- Swift 6.2+
- C++20
