import CoreGraphics
import Vision

/// Apple Vision OCR — accurate mode, language correction, off-main-thread.
final class OCRService {
    func recognize(image: CGImage, minConfidence: Float) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? []).compactMap { obs -> String? in
                        guard let candidate = obs.topCandidates(1).first,
                              candidate.confidence >= minConfidence else { return nil }
                        return candidate.string
                    }
                    cont.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    cont.resume(returning: "")
                }
            }
        }
    }
}
