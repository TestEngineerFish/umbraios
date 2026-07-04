import AVFoundation
import Speech

// MARK: - TTS Service
@MainActor
class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    private let synthesizer = AVSpeechSynthesizer()
    @Published var isSpeaking: Bool = false
    /// 当前正在朗读的消息 id（用于让每条消息的“朗读回复”按钮各自独立，只有正在播放的那条显示播放态）。
    @Published var speakingId: String?
    @Published var currentTime: TimeInterval = 0

    /// 某条消息是否正在朗读。
    func isSpeaking(id: String) -> Bool {
        isSpeaking && speakingId == id
    }

    func speak(_ text: String, id: String) {
        guard !text.isEmpty else { return }
        stop()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: LanguageManager.shared.speechLocaleIdentifier)
        utterance.rate = 0.5

        synthesizer.delegate = self
        synthesizer.speak(utterance)
        speakingId = id
        isSpeaking = true
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        speakingId = nil
        currentTime = 0
    }

    /// 切换某条消息的朗读：正在读同一条→停止；否则读这一条（会自动停掉上一条）。
    func toggle(_ text: String, id: String) {
        if isSpeaking && speakingId == id {
            stop()
        } else {
            speak(text, id: id)
        }
    }
}

// MARK: - Speech Recognizer（麦克风语音输入 → 文字）
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var available = true

    private var recognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: LanguageManager.shared.speechLocaleIdentifier))
    }
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// 切换录音；onFinal 在停止时回传最终文字。
    func toggle(onFinal: @escaping (String) -> Void) {
        if isRecording {
            stop(onFinal: onFinal)
        } else {
            start()
        }
    }

    private func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard status == .authorized, granted,
                          let recognizer = self.recognizer, recognizer.isAvailable else {
                        self.available = false
                        return
                    }
                    self.beginSession(recognizer: recognizer)
                }
            }
        }
    }

    private func beginSession(recognizer: SFSpeechRecognizer) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            transcript = ""
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || (result?.isFinal ?? false) {
                        self.teardown()
                    }
                }
            }
        } catch {
            teardown()
        }
    }

    private func stop(onFinal: @escaping (String) -> Void) {
        let final = transcript
        teardown()
        onFinal(final)
    }

    private func teardown() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            currentTime = 0
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            currentTime = 0
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let text = utterance.speechString
            if let range = Range(characterRange, in: text) {
                let substring = text[range]
                currentTime = Double(substring.count) * 0.1 // Rough estimate
            }
        }
    }
}
