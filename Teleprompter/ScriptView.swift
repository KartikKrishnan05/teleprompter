import SwiftUI

/// Edit the script, then start the prompter.
struct ScriptView: View {
    @AppStorage("script") private var script = """
        Welcome, everyone, and thank you for being here today. \
        Just speak naturally and the text follows your voice. \
        If you say something in your own words, the prompter understands and moves on.
        """
    @State private var prompter: Prompter?

    var body: some View {
        NavigationStack {
            TextEditor(text: $script)
                .font(.title3)
                .padding(.horizontal)
                .navigationTitle("Script")
                .toolbar {
                    Button("Start", systemImage: "play.fill") { prompter = Prompter(script: script) }
                        .disabled(script.allSatisfy(\.isWhitespace))
                }
        }
        .fullScreenCover(item: $prompter) { PrompterView(prompter: $0) }
    }
}

/// Full-screen teleprompter that follows the speaker's voice.
struct PrompterView: View {
    let prompter: Prompter
    @AppStorage("fontSize") private var fontSize = 48.0
    @AppStorage("mirrored") private var mirrored = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: fontSize * 0.5) {
                        ForEach(prompter.sentences) { sentence in
                            Text(styled(sentence))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                                .onTapGesture { prompter.jump(to: sentence.id) }
                                .id(sentence.id)
                        }
                    }
                    .font(.system(size: fontSize, weight: .semibold))
                    .padding(.horizontal, 48)
                    .padding(.vertical, 400)
                }
                .scrollIndicators(.hidden)
                .onChange(of: prompter.current) { _, index in
                    withAnimation(.smooth(duration: 0.6)) {
                        proxy.scrollTo(min(index, prompter.sentences.count - 1), anchor: UnitPoint(x: 0.5, y: 0.3))
                    }
                }
            }
            .scaleEffect(x: mirrored ? -1 : 1)
            .foregroundStyle(.white)
            .background(.black)
            .navigationTitle("\(min(prompter.current + 1, prompter.sentences.count)) of \(prompter.sentences.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { controls }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .task { await prompter.start() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            prompter.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("Can't Listen", isPresented: .init(get: { prompter.error != nil }, set: { _ in prompter.error = nil })) {
            Button("OK") {}
        } message: {
            Text(prompter.error ?? "")
        }
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Restart", systemImage: "arrow.counterclockwise") { prompter.jump(to: 0) }
            Button("Smaller Text", systemImage: "textformat.size.smaller") { fontSize = max(24, fontSize - 8) }
            Button("Larger Text", systemImage: "textformat.size.larger") { fontSize = min(120, fontSize + 8) }
            Toggle("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: $mirrored)
            Button(prompter.isListening ? "Pause" : "Listen",
                   systemImage: prompter.isListening ? "mic.fill" : "mic.slash") {
                if prompter.isListening { prompter.stop() } else { Task { await prompter.start() } }
            }
            .symbolEffect(.pulse, isActive: prompter.isListening)
        }
    }

    /// Dims everything already spoken, so the reading position is always obvious.
    private func styled(_ sentence: Prompter.Sentence) -> AttributedString {
        let end: String.Index = switch sentence.id {
        case ..<prompter.current: sentence.text.endIndex
        case prompter.current where prompter.spoken > 0: sentence.wordEnds[prompter.spoken - 1]
        default: sentence.text.startIndex
        }
        var spoken = AttributedString(String(sentence.text[..<end]))
        spoken.foregroundColor = Color.gray
        return spoken + AttributedString(String(sentence.text[end...]))
    }
}
