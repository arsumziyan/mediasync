import CoreML
import UIKit
import Vision

/// Image understanding fully on-device:
///  1. Apple's built-in Vision taxonomy classifier (`VNClassifyImageRequest`, ~1300 labels)
///  2. Optional custom Core ML model: drop `MediaClassifier.mlmodel` into the target and it is used
///     automatically (e.g. a Create ML image classifier trained on your own categories)
///  3. OCR (`VNRecognizeTextRequest`) so screenshots / documents / receipts become searchable
enum ImageAnalyzer {
    static func analyze(cgImage: CGImage, minConfidence: Float = 0.35, maxTags: Int = 6) async -> MediaAnalysis {
        var result = MediaAnalysis()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let classify = VNClassifyImageRequest()
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = true

        var requests: [VNRequest] = [classify, ocr]
        let custom = customModelRequest()
        if let custom { requests.append(custom) }

        // Vision work is CPU/ANE-bound and synchronous; keep it off the cooperative pool's main work.
        await Task.detached(priority: .userInitiated) {
            try? handler.perform(requests)
        }.value

        var tags: [String] = []
        if let custom, let top = (custom.results as? [VNClassificationObservation])?.first, top.confidence >= minConfidence {
            tags.append(top.identifier.lowercased())
        }
        let builtIn = (classify.results ?? [])
            .filter { $0.confidence >= minConfidence }
            .prefix(maxTags)
            .map { $0.identifier.lowercased() }
        tags.append(contentsOf: builtIn)

        let text = (ocr.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        if text.count > 15 {
            result.text = text
            tags.append("text")
            result.sentiment = SentimentTagger.sentiment(for: text)
        }

        result.tags = Array(NSOrderedSet(array: tags)) as? [String] ?? tags
        return result
    }

    static func analyze(imageAt url: URL) async -> MediaAnalysis {
        guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage else { return MediaAnalysis() }
        return await analyze(cgImage: cg)
    }

    private static func customModelRequest() -> VNCoreMLRequest? {
        guard let url = Bundle.main.url(forResource: "MediaClassifier", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url, configuration: {
                  let c = MLModelConfiguration(); c.computeUnits = .all; return c
              }()),
              let vnModel = try? VNCoreMLModel(for: model) else { return nil }
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .centerCrop
        return request
    }
}
