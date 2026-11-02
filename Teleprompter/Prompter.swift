import AVFoundation
import NaturalLanguage
import Observation
import Speech

/// Listens to the speaker and follows along in the script.
///
/// - Exact words are aligned word by word, so the prompter moves exactly as fast as the speaker talks.
/// - Paraphrases are detected with Apple's small on-device sentence-embedding model (NaturalLanguage):
///   if what was said *means* the same as the current sentence, the prompter moves on.
@MainActor @Observable
final class Prompter: Identifiable {
    struct Sentence: Identifiable {
        let id: Int
        let text: String
        let words: [String]
        let wordEnds: [String.Index]
    }

    /// Max cosine distance (0 = identical meaning) for a paraphrase to count as "said". Lower = stricter.
    static let paraphraseDistance = 0.6
    /// A paraphrase must be at least this long relative to the sentence before it's compared.
    static let paraphraseMinLength = 0.7

    let sentences: [Sentence]
    private(set) var current = 0        // index of the sentence being spoken
    private(set) var spoken = 0         // words of the current sentence already spoken
    private(set) var isListening = false
    var error: String?

    private let recognizer: SFSpeechRecognizer?
    private let embedding: NLEmbedding?
    private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var generation = 0      // ignores callbacks from cancelled tasks
    @ObservationIgnored private var heardCount = 0      // words in the running transcript
    @ObservationIgnored private var consumed = 0        // transcript words that belong to earlier sentences
    @ObservationIgnored private var resumeAt = 0        // progress kept when the recognizer restarts mid-sentence

    init(script: String) {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = script
        var sentences: [Sentence] = []
        for range in tokenizer.tokens(for: script.startIndex..<script.endIndex) {
            let text = script[range].trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = Self.tokens(in: text)
            guard !tokens.isEmpty else { continue }
            sentences.append(Sentence(id: sentences.count, text: text,
                                      words: tokens.map(Self.normalize), wordEnds: tokens.map(\.endIndex)))
        }
        self.sentences = sentences

        let language = NLLanguageRecognizer.dominantLanguage(for: script) ?? .english
        recognizer = Self.recognizer(for: language)
        embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    // MARK: Control

    func start() async {
        guard await Self.authorize() else {
            error = "Allow microphone and speech recognition access in Settings."
            return
        }
        isListening = true
        listen()
    }

    func stop() {
        isListening = false
        teardown()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func jump(to index: Int) {
        current = min(max(index, 0), sentences.count)
        spoken = 0
        resumeAt = 0
        consumed = heardCount
    }

    // MARK: Following the speaker

    private func follow(_ heard: [String]) {
        heardCount = heard.count
        guard current < sentences.count else { return }
        let window = Array(heard.dropFirst(min(consumed, heard.count)))
        let target = sentences[current].words

        spoken = Self.align(window, to: target, from: resumeAt)
        if spoken >= (target.count <= 3 ? target.count : target.count - 1) {
            jump(to: current + 1)
        } else if let match = paraphrase(of: window) {
            jump(to: match + 1)
        }
    }

    /// Greedy in-order alignment that tolerates a few skipped or misheard words.
    private static func align(_ heard: [String], to target: [String], from start: Int) -> Int {
        var position = start
        for word in heard where position < target.count {
            if let hit = target[position..<min(position + 4, target.count)].firstIndex(of: word) {
                position = hit + 1
            }
        }
        return position
    }

    /// Returns the sentence (current or one of the next two) whose meaning matches what was said.
    private func paraphrase(of heard: [String]) -> Int? {
        guard let embedding, heard.count >= 3 else { return nil }
        let said = heard.joined(separator: " ")
        let best = (current..<min(current + 3, sentences.count))
            .filter { Double(heard.count) >= Double(sentences[$0].words.count) * Self.paraphraseMinLength }
            .map { ($0, embedding.distance(between: said, and: sentences[$0].words.joined(separator: " "), distanceType: .cosine)) }
            .min { $0.1 < $1.1 }
        guard let best, best.1 < Self.paraphraseDistance else { return nil }
        return best.0
    }

    // MARK: Speech recognition

    private func listen() {
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition isn't available for this language."
            isListening = false
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        request.contextualStrings = Array(Set(sentences.flatMap(\.words)).filter { $0.count > 4 }.prefix(100))

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(into: request))
            engine.prepare()
            try engine.start()
        } catch {
            self.error = error.localizedDescription
            isListening = false
            return
        }

        generation += 1
        let token = generation
        heardCount = 0
        consumed = 0
        resumeAt = spoken
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.forward { [weak self] text, done in
            self?.handle(text, done: done, generation: token)
        })
    }

    private func handle(_ text: String?, done: Bool, generation: Int) {
        guard generation == self.generation else { return }
        if let text { follow(Self.tokens(in: text).map(Self.normalize)) }
        guard done else { return }
        // The recognizer ends after long pauses — quietly start a new session.
        teardown()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if isListening, task == nil { listen() }
        }
    }

    private func teardown() {
        generation += 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    // MARK: Helpers (nonisolated: called from audio / recognition threads)

    nonisolated private static func tap(into request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func forward(
        _ handler: @escaping @MainActor (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in handler(text, done) }
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    nonisolated private static func recognizer(for language: NLLanguage) -> SFSpeechRecognizer? {
        let code = Locale.Language(identifier: language.rawValue).languageCode
        if Locale.current.language.languageCode == code { return SFSpeechRecognizer(locale: .current) }
        let locale = SFSpeechRecognizer.supportedLocales()
            .filter { $0.language.languageCode == code }
            .min { $0.identifier < $1.identifier }
        return locale.flatMap(SFSpeechRecognizer.init(locale:)) ?? SFSpeechRecognizer()
    }

    nonisolated private static func tokens(in text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }

    nonisolated private static func normalize(_ word: Substring) -> String {
        word.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }
}
