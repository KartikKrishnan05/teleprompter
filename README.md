# Teleprompter

A minimal SwiftUI iPad teleprompter that follows your voice — fully on device.

- **Follows your pace** – on-device speech recognition aligns what you say with the script word by word, so the text moves exactly as fast (or slow) as you speak. Spoken words are dimmed.
- **Understands paraphrases** – Apple's small built-in sentence-embedding model (`NLEmbedding`, NaturalLanguage framework) compares the *meaning* of what you said with the current sentence (and the next two). Say it in your own words, or skip a sentence, and the prompter moves on.
- **Private** – no network, no downloads; script language is auto-detected (sentence embeddings: English, German, French, Spanish, Italian, Portuguese, Chinese).

## Run

1. Open `Teleprompter.xcodeproj` in Xcode 16 or later.
2. Select your team under *Signing & Capabilities* (and change the bundle ID if needed).
3. Run on an iPad (iPadOS 17+). The simulator works, but a real device gives the best recognition.

## Use

Type or paste your script, tap **Start**, and speak. Tap any sentence to jump there. Toolbar: restart, text size, mirror (for beam-splitter glass), pause listening.

## Code

| File | Purpose |
| --- | --- |
| `Prompter.swift` | Speech recognition, word alignment, paraphrase detection |
| `ScriptView.swift` | Script editor and full-screen prompter |
| `TeleprompterApp.swift` | App entry point |

Tune `Prompter.paraphraseDistance` (lower = stricter) and `paraphraseMinLength` if it moves on too early or too late.
