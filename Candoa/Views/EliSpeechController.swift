@preconcurrency import AVFoundation
@preconcurrency import Speech
import SwiftUI

@MainActor
final class AISidebarSpeechController: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var statusMessage: String?
    @Published private(set) var elapsedText = "00:00"

    // Do not construct speech or audio capture objects when Eli appears. Creating
    // an audio input graph can cross macOS's microphone privacy boundary, so these
    // exist only for an explicit dictation request.
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var elapsedTask: Task<Void, Never>?
    private var startedAt: Date?

    var displayText: String {
        if !transcript.isEmpty {
            return transcript
        }
        return statusMessage ?? String(localized: "Listening...")
    }

    func startListening() async {
        guard !isListening else { return }

        transcript = ""
        statusMessage = String(localized: "Listening...")
        elapsedText = "00:00"

        guard await requestSpeechAuthorization() else {
            statusMessage = String(localized: "Speech recognition is not allowed.")
            return
        }

        guard await requestMicrophoneAuthorization() else {
            statusMessage = String(localized: "Microphone access is not allowed.")
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            statusMessage = String(localized: "Speech recognition is unavailable.")
            return
        }

        do {
            try startAudioRecognition(with: recognizer)
        } catch {
            stopAudioRecognition()
            statusMessage = String(localized: "Could not start dictation.")
        }
    }

    @discardableResult
    func stopListening() -> String {
        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopAudioRecognition()
        statusMessage = nil
        return finalTranscript
    }

    func cancelListening() {
        transcript = ""
        stopAudioRecognition()
        statusMessage = nil
    }

    private func startAudioRecognition(with recognizer: SFSpeechRecognizer) throws {
        stopAudioRecognition()
        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        startedAt = Date()
        startElapsedClock()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stopAudioRecognition()
                }
            }
        }
    }

    private func stopAudioRecognition() {
        if let audioEngine {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        speechRecognizer = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        elapsedTask?.cancel()
        elapsedTask = nil
        startedAt = nil
        isListening = false
    }

    private func startElapsedClock() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self?.updateElapsedText()
                }
            }
        }
    }

    private func updateElapsedText() {
        guard let startedAt else {
            elapsedText = "00:00"
            return
        }

        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        elapsedText = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isAllowed in
                    continuation.resume(returning: isAllowed)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
