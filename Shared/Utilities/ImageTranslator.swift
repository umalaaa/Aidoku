//
//  ImageTranslator.swift
//  Aidoku
//
//  Created by Jules on 10/26/24.
//

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

class ImageTranslator {
    static let shared = ImageTranslator()

    // Supported aspect ratios for Gemini Vision
    private let supportedRatios: [CGFloat] = [
        1.0,        // 1:1
        3.0 / 2.0,  // 3:2
        2.0 / 3.0,  // 2:3
        4.0 / 3.0,  // 4:3
        3.0 / 4.0,  // 3:4
        5.0 / 4.0,  // 5:4
        4.0 / 5.0,  // 4:5
        16.0 / 9.0, // 16:9
        9.0 / 16.0, // 9:16
        21.0 / 9.0, // 21:9
        9.0 / 21.0  // 9:21
    ]

    func translate(image: PlatformImage, apiKey: String, targetLang: String, model: String = "gemini-1.5-pro") async throws -> PlatformImage {
        guard let cgImage = image.cgImage else {
            throw TranslationError.invalidImage
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let ratio = width / height

        // Split if necessary (Webtoon strip logic or too large)
        // Gemini has a ~4096px limit per side usually, or total pixel limit.
        // Splitting very tall images is safer.
        if ratio < 0.6 || ratio > 1.8 || width > 4000 || height > 4000 {
            return try await splitAndTranslate(image: image, apiKey: apiKey, targetLang: targetLang, model: model)
        }

        // Single image translation (with padding if needed)
        return try await processSingleImage(image: image, apiKey: apiKey, targetLang: targetLang, model: model)
    }

    private func splitAndTranslate(image: PlatformImage, apiKey: String, targetLang: String, model: String) async throws -> PlatformImage {
        guard let cgImage = image.cgImage else { throw TranslationError.invalidImage }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let ratio = width / height

        var parts: [CGRect] = []

        if ratio < 0.6 {
            // Vertical split (Tall image)
            // Split into chunks of height approx equal to width * 1.5 (3:2 ratio roughly, vertical)
            // or just ensure max dimension < 3000
            let targetHeight = min(height, 3000)
            let count = Int(ceil(height / targetHeight))
            let actualPartHeight = height / CGFloat(count)

            for i in 0..<count {
                parts.append(CGRect(x: 0, y: CGFloat(i) * actualPartHeight, width: width, height: actualPartHeight))
            }
        } else {
            // Horizontal split (Wide image)
            let targetWidth = min(width, 3000)
            let count = Int(ceil(width / targetWidth))
            let actualPartWidth = width / CGFloat(count)

            for i in 0..<count {
                parts.append(CGRect(x: CGFloat(i) * actualPartWidth, y: 0, width: actualPartWidth, height: height))
            }
        }

        // Translate parts sequentially to avoid rate limits
        var translatedImages: [(Int, PlatformImage)] = []

        for (index, rect) in parts.enumerated() {
            guard let partCG = cgImage.cropping(to: rect) else { continue }
            let partImage = PlatformImage(cgImage: partCG)
            let translatedPart = try await processSingleImage(image: partImage, apiKey: apiKey, targetLang: targetLang, model: model)
            translatedImages.append((index, translatedPart))
        }

        return stitchImages(originalSize: CGSize(width: width, height: height), parts: parts, images: translatedImages.map { $0.1 })
    }

    private func processSingleImage(image: PlatformImage, apiKey: String, targetLang: String, model: String) async throws -> PlatformImage {
        guard let cgImage = image.cgImage else { throw TranslationError.invalidImage }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let bestRatio = findBestRatio(width: width, height: height)

        // Check if padding is needed
        let currentRatio = width / height
        let needsPadding = abs(currentRatio - bestRatio) > 0.01

        let imageToTranslate: PlatformImage
        let paddingInfo: PaddingInfo?

        if needsPadding {
            let info = calculatePadding(width: width, height: height, targetRatio: bestRatio)
            imageToTranslate = padImage(image, info: info)
            paddingInfo = info
        } else {
            imageToTranslate = image
            paddingInfo = nil
        }

        // Call API
        let resultImage = try await callGemini(image: imageToTranslate, apiKey: apiKey, targetLang: targetLang, model: model)

        // Crop if padded
        if let info = paddingInfo {
            return cropImage(resultImage, info: info, originalSize: CGSize(width: width, height: height))
        }

        return resultImage
    }

    private func stitchImages(originalSize: CGSize, parts: [CGRect], images: [PlatformImage]) -> PlatformImage {
        #if canImport(UIKit)
        UIGraphicsBeginImageContextWithOptions(originalSize, true, 1.0)

        for (i, rect) in parts.enumerated() {
            if i < images.count {
                images[i].draw(in: rect)
            }
        }

        let result = UIGraphicsGetImageFromCurrentImageContext() ?? PlatformImage()
        UIGraphicsEndImageContext()
        return result
        #else
        // Simplified macOS placeholder if needed
        return PlatformImage()
        #endif
    }

    private func findBestRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        let currentRatio = width / height
        return supportedRatios.min(by: { abs($0 - currentRatio) < abs($1 - currentRatio) }) ?? 1.0
    }

    struct PaddingInfo {
        let newSize: CGSize
        let origin: CGPoint
    }

    private func calculatePadding(width: CGFloat, height: CGFloat, targetRatio: CGFloat) -> PaddingInfo {
        var newWidth = width
        var newHeight = width / targetRatio

        if newHeight < height {
            newHeight = height
            newWidth = height * targetRatio
        }

        let x = (newWidth - width) / 2
        let y = (newHeight - height) / 2

        return PaddingInfo(newSize: CGSize(width: newWidth, height: newHeight), origin: CGPoint(x: x, y: y))
    }

    private func padImage(_ image: PlatformImage, info: PaddingInfo) -> PlatformImage {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: info.newSize, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: info.newSize))
            image.draw(in: CGRect(origin: info.origin, size: image.size))
        }
        #else
        return image
        #endif
    }

    private func cropImage(_ image: PlatformImage, info: PaddingInfo, originalSize: CGSize) -> PlatformImage {
         guard let cgImage = image.cgImage else { return image }
         // Note: info.origin is where we drew the image. So we need to crop that rect.
         // However, the result image from Gemini might have different dimensions (if it hallucinates size),
         // but assuming it respects size.
         // Also, if we padded, the content is at info.origin.

         let cropRect = CGRect(origin: info.origin, size: originalSize)
         guard let cropped = cgImage.cropping(to: cropRect) else { return image }
         return PlatformImage(cgImage: cropped)
    }

    private func callGemini(image: PlatformImage, apiKey: String, targetLang: String, model: String) async throws -> PlatformImage {
        guard let data = image.pngData() else { throw TranslationError.encodingFailed }
        let base64 = data.base64EncodedString()

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = """
        You are a professional image translation tool. Please identify all text content in the image and translate it completely into \(targetLang).

        Important requirements:
        1. Output image size must be exactly the same as input.
        2. Maintain original layout, ordering, and positions.
        3. Translate text to \(targetLang) naturally.
        4. Preserve all non-text elements (background, bubbles, etc.).
        5. Return ONLY the image.
        """

        let requestBody = GeminiRequest(contents: [
            .init(parts: [
                .init(text: prompt),
                .init(inlineData: .init(mimeType: "image/png", data: base64))
            ])
        ])

        request.httpBody = try JSONEncoder().encode(requestBody)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
             if let errorText = String(data: responseData, encoding: .utf8) {
                 print("Gemini Error: \(errorText)")
             }
             throw TranslationError.apiError
        }

        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: responseData)

        guard let part = geminiResponse.candidates?.first?.content?.parts?.first(where: { $0.inlineData != nil }),
              let base64Response = part.inlineData?.data,
              let responseData = Data(base64Encoded: base64Response),
              let responseImage = PlatformImage(data: responseData) else {
            throw TranslationError.noImageInResponse
        }

        return responseImage
    }

    enum TranslationError: Error {
        case invalidImage
        case encodingFailed
        case apiError
        case noImageInResponse
    }
}

// Codable Structs
struct GeminiRequest: Codable {
    let contents: [Content]

    struct Content: Codable {
        let parts: [Part]
    }

    struct Part: Codable {
        let text: String?
        let inlineData: InlineData?

        init(text: String? = nil, inlineData: InlineData? = nil) {
            self.text = text
            self.inlineData = inlineData
        }
    }

    struct InlineData: Codable {
        let mimeType: String
        let data: String
    }
}

struct GeminiResponse: Codable {
    let candidates: [Candidate]?

    struct Candidate: Codable {
        let content: Content?
    }

    struct Content: Codable {
        let parts: [Part]?
    }

    struct Part: Codable {
        let text: String?
        let inlineData: InlineData?
    }

    struct InlineData: Codable {
        let mimeType: String
        let data: String
    }
}
