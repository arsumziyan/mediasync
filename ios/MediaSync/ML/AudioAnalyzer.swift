import Foundation
import Speech
import SoundAnalysis

/// Audio understanding on-device:
///  - SoundAnalysis built-in classifier (speech, music, laughter, dog bark, ...)
///  - Optional on-device speech transcription (never uses Apple's servers) -> sentiment + keywords
enum AudioAnalyzer {
    static func analyze(fileAt url: URL, minConfidence: Double = 0.5) async -> MediaAnalysis {
        var result = MediaAnalysis()
        result.tags = await soundLabels(url: url, minConfidence: minConfidence)

        if let transcript = await transcribe(url: url), !transcript.isEmpty {
            result.text = transcript
            result.sentiment = SentimentTagger.sentiment(for: transcript)
            result.tags += SentimentTagger.keywords(in: transcript, limit: 4)
        }
        result.tags = Array(NSOrderedSet(array: result.tags)) as? [String] ?? result.tags
        return result
    }

    // MARK: Sound classification

    private final class Observer: NSObject, SNResultsObserving {
        var best: [String: Double] = [:]
        var continuation: CheckedContinuation<[String: Double], Never>?

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            for c in r.classifications where c.confidence > (best[c.identifier] ?? 0) {
                best[c.identifier] = c.confidence
            }
        }
        func request(_ request: SNRequest, didFailWithError error: Error) { finish() }
        func requestDidComplete(_ request: SNRequest) { finish() }
        private func finish() { continuation?.resume(returning: best); continuation = nil }
    }

    private static func soundLabels(url: URL, minConfidence: Double) async -> [String] {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        let observer = Observer()
        let scores: [String: Double] = await withCheckedContinuation { cont in
            observer.continuation = cont
            do {
                try analyzer.add(request, withObserver: observer)
                analyzer.analyze { _ in }      // completion handled by observer
            } catch {
                cont.resume(returning: [:])
            }
        }
        return scores.filter { $0.value >= minConfidence }
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { $0.key.replacingOccurrences(of: "_", with: " ") }
    }

    // MARK: Transcription (on-device only)

    private static func transcribe(url: URL) async -> String? {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized,
              let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true     // audio never leaves the phone
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    finished = true
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
