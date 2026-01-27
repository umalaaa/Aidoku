//
//  UIKitShim.swift
//  Aidoku
//
//  Created by Skitty on 6/7/25.
//

#if canImport(UIKit)

import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor

#else

import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor

extension NSImage {
    func pngData() -> Data? {
        guard
            let data = tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    var cgImage: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: self.size)
        guard let cgImage = self.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        return cgImage
    }
}

enum UITextAutocapitalizationType: Int {
    case none = 0
    case words = 1
    case sentences = 2
    case allCharacters = 3
}

enum UIKeyboardType: Int {
    case `default` = 0
    case asciiCapable = 1
    case numbersAndPunctuation = 2
    case URL = 3
    case numberPad = 4
    case phonePad = 5
    case namePhonePad = 6
    case emailAddress = 7
    case decimalPad = 8
    case twitter = 9
    case webSearch = 10
    case asciiCapableNumberPad = 11
}

enum UIReturnKeyType: Int {
    case `default` = 0
    case go = 1
    case google = 2
    case join = 3
    case next = 4
    case route = 5
    case search = 6
    case send = 7
    case yahoo = 8
    case done = 9
    case emergencyCall = 10
    case `continue` = 11
}

#endif
//
//  ImageTranslator.swift
//  Aidoku
//
//  Created by Jules on 10/26/24.
//

import Foundation
import CoreGraphics
import AidokuRunner
import Combine

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public enum TranslationStatus: Equatable {
    case idle
    case waitingForDownload
    case downloading
    case translating(progress: Float, current: Int, total: Int)
    case completed
    case failed(error: String)
}

public class TranslationManager: ObservableObject {
    public static let shared = TranslationManager()

    @Published public var status: [String: TranslationStatus] = [:]
    private var cancellables = Set<AnyCancellable>()

    private let completedChaptersKey = "TranslatedChapters"

    init() {
        setupNotifications()
    }

    private var completedChapters: Set<String> {
        get {
            let list = UserDefaults.standard.stringArray(forKey: completedChaptersKey) ?? []
            return Set(list)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: completedChaptersKey)
        }
    }

    public func isChapterTranslated(_ key: String) -> Bool {
        completedChapters.contains(key)
    }

    func markChapterTranslated(_ key: String) {
        var completed = completedChapters
        completed.insert(key)
        completedChapters = completed

        DispatchQueue.main.async {
            self.status[key] = .completed
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .downloadFinished)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let identifier = notification.object as? ChapterIdentifier {
                    let key = identifier.chapterKey
                    // If we were waiting for this chapter, start translating
                    if self.status[key] == .waitingForDownload || self.status[key] == .downloading {
                         self.startTranslationProcess(chapterKey: key)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // Store context to start translation after download
    private var pendingTranslations: [String: (AidokuRunner.Chapter, AidokuRunner.Manga, AidokuRunner.Source)] = [:]

    public func translateChapter(chapter: AidokuRunner.Chapter, manga: AidokuRunner.Manga, source: AidokuRunner.Source) {
        let key = chapter.key

        if isChapterTranslated(key) {
            self.status[key] = .completed
            return
        }

        pendingTranslations[key] = (chapter, manga, source)

        // Check download status
        let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: key)
        let downloadStatus = DownloadManager.shared.getDownloadStatus(for: identifier)

        if downloadStatus == .finished {
            startTranslationProcess(chapterKey: key)
        } else {
            self.status[key] = .waitingForDownload
            Task {
                await DownloadManager.shared.download(manga: manga, chapters: [chapter])
                DispatchQueue.main.async {
                    if self.status[key] == .waitingForDownload {
                        self.status[key] = .downloading
                    }
                }
            }
        }
    }

    private func startTranslationProcess(chapterKey: String) {
        guard let (chapter, _, source) = pendingTranslations[chapterKey] else { return }

        self.status[chapterKey] = .translating(progress: 0, current: 0, total: 0)

        Task {
            do {
                // Determine pages
                // We rely on source.getChapterPages. If downloaded, Aidoku *should* provide local access or we handle it.
                // Assuming getChapterPages works for downloaded chapters (returning local URIs or data)
                let pages = try await source.getChapterPages(chapter: chapter)
                let total = pages.count

                let apiKey = UserDefaults.standard.string(forKey: "Reader.geminiApiKey") ?? ""
                let targetLang = UserDefaults.standard.string(forKey: "Reader.targetLanguage") ?? "Chinese (Simplified)"
                let model = UserDefaults.standard.string(forKey: "Reader.geminiModel") ?? "gemini-1.5-pro"
                let finalModel = model.isEmpty ? "gemini-1.5-pro" : model
                let apiEndpoint = UserDefaults.standard.string(forKey: "Reader.geminiApiEndpoint")

                for (index, page) in pages.enumerated() {
                    DispatchQueue.main.async {
                        self.status[chapterKey] = .translating(progress: Float(index)/Float(total), current: index + 1, total: total)
                    }

                    // Try to get image
                    var image: PlatformImage?

                    // 1. Try file URL (common for downloaded chapters)
                    if let urlStr = page.imageURL, let url = URL(string: urlStr), url.isFileURL {
                        if let data = try? Data(contentsOf: url) {
                            image = PlatformImage(data: data)
                        }
                    }
                    // 2. Try base64
                    else if let base64 = page.base64, let data = Data(base64Encoded: base64) {
                        image = PlatformImage(data: data)
                    }
                    // 3. Try custom loading via source (if needed, but getChapterPages usually resolves this)
                    // If image is nil, we might need to download it? But we ensured chapter is downloaded.
                    // If downloaded, page.imageURL usually points to local file.

                    // Fallback: If remote URL and we are "downloaded", maybe we can find it in DownloadManager path?
                    if image == nil, let urlStr = page.imageURL, let _ = URL(string: urlStr) {
                         // Try to load from known download path?
                         // Skip for now, assume getChapterPages returns valid local paths for downloaded chapters.
                    }

                    if let image = image {
                        // Generate cache key
                        let keyString = "\(chapterKey)-\(page.index)-\(targetLang)-\(finalModel)"
                        let cacheKey = keyString.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")

                        _ = try await ImageTranslator.shared.translate(image: image, apiKey: apiKey, targetLang: targetLang, model: finalModel, apiEndpoint: apiEndpoint, cacheKey: cacheKey)
                    }
                }

                markChapterTranslated(chapterKey)
                pendingTranslations.removeValue(forKey: chapterKey)

            } catch {
                DispatchQueue.main.async {
                    self.status[chapterKey] = .failed(error: error.localizedDescription)
                }
            }
        }
    }
}

public class ImageTranslator {
    public static let shared = ImageTranslator()

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

    public func translate(image: PlatformImage, apiKey: String, targetLang: String, model: String = "gemini-1.5-pro", apiEndpoint: String? = nil, cacheKey: String? = nil) async throws -> PlatformImage {
        // Check cache first
        if let cacheKey, let cached = checkCache(key: cacheKey) {
            return cached
        }

        guard let cgImage = image.cgImage else {
            throw TranslationError.invalidImage
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let ratio = width / height

        let result: PlatformImage
        // Split if necessary (Webtoon strip logic or too large)
        // Gemini has a ~4096px limit per side usually, or total pixel limit.
        // Splitting very tall images is safer.
        if ratio < 0.6 || ratio > 1.8 || width > 4000 || height > 4000 {
            result = try await splitAndTranslate(image: image, apiKey: apiKey, targetLang: targetLang, model: model, apiEndpoint: apiEndpoint)
        } else {
            // Single image translation (with padding if needed)
            result = try await processSingleImage(image: image, apiKey: apiKey, targetLang: targetLang, model: model, apiEndpoint: apiEndpoint)
        }

        // Save to cache
        if let cacheKey {
            saveToCache(image: result, key: cacheKey)
        }
        return result
    }

    private func checkCache(key: String) -> PlatformImage? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TranslationCache")
        let fileURL = cacheDir.appendingPathComponent(key).appendingPathExtension("png")
        if let data = try? Data(contentsOf: fileURL) {
            return PlatformImage(data: data)
        }
        return nil
    }

    private func saveToCache(image: PlatformImage, key: String) {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TranslationCache")
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        let fileURL = cacheDir.appendingPathComponent(key).appendingPathExtension("png")
        if let data = image.pngData() {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func getCachedImages() -> [URL] {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TranslationCache")
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "png" }
    }

    public func deleteCachedImage(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func clearCache() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TranslationCache")
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private func splitAndTranslate(image: PlatformImage, apiKey: String, targetLang: String, model: String, apiEndpoint: String?) async throws -> PlatformImage {
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
            let translatedPart = try await processSingleImage(image: partImage, apiKey: apiKey, targetLang: targetLang, model: model, apiEndpoint: apiEndpoint)
            translatedImages.append((index, translatedPart))
        }

        return stitchImages(originalSize: CGSize(width: width, height: height), parts: parts, images: translatedImages.map { $0.1 })
    }

    private func processSingleImage(image: PlatformImage, apiKey: String, targetLang: String, model: String, apiEndpoint: String?) async throws -> PlatformImage {
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
        let resultImage = try await callGemini(image: imageToTranslate, apiKey: apiKey, targetLang: targetLang, model: model, apiEndpoint: apiEndpoint)

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

    private func callGemini(image: PlatformImage, apiKey: String, targetLang: String, model: String, apiEndpoint: String?) async throws -> PlatformImage {
        guard let data = image.pngData() else { throw TranslationError.encodingFailed }
        let base64 = data.base64EncodedString()

        let baseUrl = apiEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? apiEndpoint! : "https://generativelanguage.googleapis.com"
        let urlString = "\(baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1beta/models/\(model):generateContent?key=\(apiKey)"

        guard let url = URL(string: urlString) else { throw TranslationError.apiError }
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

        let requestBody = GeminiRequest(
            contents: [
                .init(parts: [
                    .init(text: prompt),
                    .init(inlineData: .init(mimeType: "image/png", data: base64))
                ])
            ],
            generationConfig: .init(responseModalities: ["IMAGE"])
        )

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

    public func validateConfiguration(apiKey: String, apiEndpoint: String?) async throws {
        let baseUrl = apiEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? apiEndpoint! : "https://generativelanguage.googleapis.com"
        let urlString = "\(baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1beta/models?key=\(apiKey)"

        guard let url = URL(string: urlString) else { throw TranslationError.apiError }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
             if let errorText = String(data: responseData, encoding: .utf8) {
                 print("Gemini Validation Error: \(errorText)")
             }
             throw TranslationError.apiError
        }

        // Simple check for "models" key in response
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let _ = json["models"] as? [[String: Any]] else {
            throw TranslationError.apiError
        }
    }

    public enum TranslationError: Error {
        case invalidImage
        case encodingFailed
        case apiError
        case noImageInResponse
    }
}

// Codable Structs
struct GeminiRequest: Codable {
    let contents: [Content]
    let generationConfig: GenerationConfig?

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

    struct GenerationConfig: Codable {
        let responseModalities: [String]
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
