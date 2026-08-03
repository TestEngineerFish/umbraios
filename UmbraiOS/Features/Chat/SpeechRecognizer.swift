// 麦克风语音输入 → 文字。
//
// 原来和一个 TTSService（朗读回复）挤在 Utils/TTSService.swift 里，
// 而 TTSService 全项目没有任何调用点 —— 那是很早的一版「朗读秘书回复」留下的，
// 界面上早就没有入口了，一并删掉，这里只留还在用的识别器。
//
// 使用方：聊天页的「按住说话」（UmbraVoiceInput）。
import AVFoundation
import Speech

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
