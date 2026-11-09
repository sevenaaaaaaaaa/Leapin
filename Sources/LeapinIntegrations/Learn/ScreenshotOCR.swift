import Foundation
import CoreGraphics
import Vision
import LeapinCore

/// On-device OCR for screenshots, backed by Vision's accurate text recogniser.
public enum ScreenshotOCR {
    /// Chinese first, English second — matches the mixed-language UI screenshots
    /// users actually feed into 学习 mode.
    public static let recognitionLanguages = ["zh-Hans", "en-US"]

    public static func recognize(imageURL: URL) throws -> OCRResult {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw LeapinError.invalidConfiguration("image not found: \(imageURL.lastPathComponent)")
        }
        let request = makeRequest()
        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw LeapinError.unsupported("Vision OCR failed: \(error.localizedDescription)")
        }
        return collect(from: request)
    }

    public static func recognize(cgImage: CGImage) throws -> OCRResult {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw LeapinError.unsupported("Vision OCR failed: \(error.localizedDescription)")
        }
        return collect(from: request)
    }

    static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = true
        return request
    }

    /// Vision uses a bottom-left origin, so `midY` descending is reading order.
    static func collect(from request: VNRecognizeTextRequest) -> OCRResult {
        let observations = (request.results ?? []).sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        var lines: [String] = []
        var confidences: [Double] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard text.isEmpty == false else { continue }
            lines.append(text)
            confidences.append(Double(candidate.confidence))
        }
        let mean = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
        return OCRResult(text: lines.joined(separator: "\n"), lines: lines, confidence: mean)
    }
}
