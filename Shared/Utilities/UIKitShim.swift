//
//  UIKitShim.swift
//  Aidoku
//
//  Created by Skitty on 6/7/25.
//

import AidokuRunner
import CryptoKit
import Foundation
import ZIPFoundation

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

struct ImageTranslationSettings: Sendable {
    static let enabledKey = "ImageTranslation.enabled"
    static let apiKeyKey = "ImageTranslation.apiKey"
    static let modelKey = "ImageTranslation.model"
    static let endpointKey = "ImageTranslation.endpoint"
    static let languageKey = "ImageTranslation.language"

    static let defaultModel = "gemini-1.5-flash"
    static let defaultEndpoint = "https://generativelanguage.googleapis.com/v1beta/models"
    static let defaultLanguage = "en"
    static let defaultMaxSegmentHeight: CGFloat = 2048
    static let defaultPaddingAspectRatio: CGFloat = 1.0

    let enabled: Bool
    let apiKey: String
    let model: String
    let endpoint: String
    let language: String
    let maxSegmentHeight: CGFloat
    let paddingAspectRatio: CGFloat

    static func current() -> ImageTranslationSettings {
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        let endpoint = defaults.string(forKey: endpointKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultEndpoint
        let language = defaults.string(forKey: languageKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultLanguage
        return ImageTranslationSettings(
            enabled: defaults.bool(forKey: enabledKey),
            apiKey: defaults.string(forKey: apiKeyKey) ?? "",
            model: model,
            endpoint: endpoint,
            language: language,
            maxSegmentHeight: defaultMaxSegmentHeight,
            paddingAspectRatio: defaultPaddingAspectRatio
        )
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var cacheSignature: String {
        [model, language, "v1"].joined(separator: "|")
    }
}

struct ImageTranslationUpdate: Sendable {
    let sourceKey: String
    let mangaKey: String
    let chapterKey: String
    let pageIndex: Int
}

enum ImageTranslationCache {
    static let directory = FileManager.default.documentDirectory
        .appendingPathComponent("ImageTranslations", isDirectory: true)

    static func cacheKey(
        sourceKey: String,
        mangaKey: String,
        chapterKey: String,
        pageIndex: Int,
        settings: ImageTranslationSettings
    ) -> String {
        let payload = [
            sourceKey,
            mangaKey,
            chapterKey,
            String(pageIndex),
            settings.cacheSignature
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func imageURL(
        sourceKey: String,
        mangaKey: String,
        chapterKey: String,
        pageIndex: Int,
        settings: ImageTranslationSettings
    ) -> URL {
        let chapterDirectory = directory
            .appendingSafePathComponent(sourceKey)
            .appendingSafePathComponent(mangaKey)
            .appendingSafePathComponent(chapterKey)
        let key = cacheKey(
            sourceKey: sourceKey,
            mangaKey: mangaKey,
            chapterKey: chapterKey,
            pageIndex: pageIndex,
            settings: settings
        )
        return chapterDirectory.appendingPathComponent("\(key).png")
    }

    static func translatedImageURL(
        for page: Page,
        mangaKey: String,
        settings: ImageTranslationSettings
    ) -> URL? {
        guard page.type == .imagePage, page.index >= 0 else { return nil }
        let url = imageURL(
            sourceKey: page.sourceId,
            mangaKey: mangaKey,
            chapterKey: page.chapterId,
            pageIndex: page.index,
            settings: settings
        )
        return url.exists ? url : nil
    }

    static func store(
        image: PlatformImage,
        sourceKey: String,
        mangaKey: String,
        chapterKey: String,
        pageIndex: Int,
        settings: ImageTranslationSettings
    ) throws -> URL {
        let url = imageURL(
            sourceKey: sourceKey,
            mangaKey: mangaKey,
            chapterKey: chapterKey,
            pageIndex: pageIndex,
            settings: settings
        )
        let directory = url.deletingLastPathComponent()
        if !directory.exists {
            directory.createDirectory()
        }
        guard let data = image.pngData() else {
            throw ImageTranslationError.invalidImage
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func clearCache(manga: AidokuRunner.Manga? = nil) {
        let target = if let manga {
            directory
                .appendingSafePathComponent(manga.sourceKey)
                .appendingSafePathComponent(manga.key)
        } else {
            directory
        }
        if target.exists {
            target.removeItem()
        }
    }
}

enum ImageTranslationError: Error {
    case invalidImage
    case invalidResponse
    case requestFailed
    case notConfigured
    case downloadRequired
}

actor ImageTranslator {
    private let session: URLSession = .shared

    func translate(image: PlatformImage, settings: ImageTranslationSettings) async throws -> PlatformImage {
        let segments = splitImageIfNeeded(image, settings: settings)
        var translatedSegments: [PlatformImage] = []
        for segment in segments {
            let padded = padImageIfNeeded(segment, settings: settings)
            let translated = try await translateSegment(padded, settings: settings)
            translatedSegments.append(translated)
        }
        if translatedSegments.count == 1, let first = translatedSegments.first {
            return first
        }
        return stitchImagesVertically(translatedSegments)
    }

    private func translateSegment(
        _ image: PlatformImage,
        settings: ImageTranslationSettings
    ) async throws -> PlatformImage {
        guard settings.isConfigured else {
            throw ImageTranslationError.notConfigured
        }
        guard let imageData = image.pngData() else {
            throw ImageTranslationError.invalidImage
        }
        let base64 = imageData.base64EncodedString()

        let endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var baseURLString = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        if !baseURLString.hasSuffix("/models") {
            baseURLString = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            baseURLString += "/models"
        }
        let urlString = "\(baseURLString)/\(model):generateContent?key=\(settings.apiKey)"
        guard let url = URL(string: urlString) else {
            throw ImageTranslationError.requestFailed
        }

        let prompt = "Translate the text in this manga image to \(settings.language) and return only the translated image."
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        ["inlineData": ["mimeType": "image/png", "data": base64]]
                    ]
                ]
            ],
            "generationConfig": [
                "response_mime_type": "image/png"
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw ImageTranslationError.requestFailed
        }

        guard
            let payload = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let candidates = payload["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw ImageTranslationError.invalidResponse
        }

        for part in parts {
            if
                let inlineData = part["inlineData"] as? [String: Any],
                let dataString = inlineData["data"] as? String,
                let imageData = Data(base64Encoded: dataString),
                let translated = PlatformImage(data: imageData)
            {
                return translated
            }
        }
        throw ImageTranslationError.invalidResponse
    }

    private func splitImageIfNeeded(
        _ image: PlatformImage,
        settings: ImageTranslationSettings
    ) -> [PlatformImage] {
        guard let cgImage = image.cgImage else { return [image] }
        let height = cgImage.height
        let maxHeight = Int(settings.maxSegmentHeight)
        guard height > maxHeight else { return [image] }

        var segments: [PlatformImage] = []
        var offset = 0
        while offset < height {
            let segmentHeight = min(maxHeight, height - offset)
            let rect = CGRect(x: 0, y: offset, width: cgImage.width, height: segmentHeight)
            if let segmentImage = cgImage.cropping(to: rect) {
                segments.append(makePlatformImage(from: segmentImage))
            }
            offset += segmentHeight
        }
        return segments
    }

    private func padImageIfNeeded(
        _ image: PlatformImage,
        settings: ImageTranslationSettings
    ) -> PlatformImage {
        guard let cgImage = image.cgImage else { return image }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let currentRatio = width / height
        let targetRatio = settings.paddingAspectRatio
        guard abs(currentRatio - targetRatio) > 0.01 else { return image }

        let newSize: CGSize
        if currentRatio < targetRatio {
            newSize = CGSize(width: height * targetRatio, height: height)
        } else {
            newSize = CGSize(width: width, height: width / targetRatio)
        }
        return drawImageOnCanvas(image: image, size: newSize)
    }

    private func drawImageOnCanvas(image: PlatformImage, size: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let origin = CGPoint(
                x: (size.width - image.size.width) / 2,
                y: (size.height - image.size.height) / 2
            )
            image.draw(at: origin)
        }
        #else
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        let origin = CGPoint(
            x: (size.width - image.size.width) / 2,
            y: (size.height - image.size.height) / 2
        )
        image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        newImage.unlockFocus()
        return newImage
        #endif
    }

    private func stitchImagesVertically(_ images: [PlatformImage]) -> PlatformImage {
        guard let first = images.first else { return PlatformImage() }
        let width = images.map { $0.size.width }.max() ?? first.size.width
        let totalHeight = images.reduce(0) { $0 + $1.size.height }
        let canvasSize = CGSize(width: width, height: totalHeight)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { _ in
            var offset: CGFloat = 0
            for image in images {
                let origin = CGPoint(x: (width - image.size.width) / 2, y: offset)
                image.draw(at: origin)
                offset += image.size.height
            }
        }
        #else
        let newImage = NSImage(size: canvasSize)
        newImage.lockFocus()
        var offset: CGFloat = 0
        for image in images {
            let origin = CGPoint(x: (width - image.size.width) / 2, y: offset)
            image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            offset += image.size.height
        }
        newImage.unlockFocus()
        return newImage
        #endif
    }

    private func makePlatformImage(from cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: .zero)
        #endif
    }
}

actor TranslationManager {
    static let shared = TranslationManager()
    private let translator = ImageTranslator()

    func translateDownloadedChapters(
        manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter]
    ) async {
        for chapter in chapters {
            _ = await translateChapter(manga: manga, chapter: chapter)
        }
    }

    func translateChapter(
        manga: AidokuRunner.Manga,
        chapter: AidokuRunner.Chapter
    ) async -> Bool {
        let settings = ImageTranslationSettings.current()
        guard settings.enabled else { return false }
        guard settings.isConfigured else { return false }

        let identifier = ChapterIdentifier(
            sourceKey: manga.sourceKey,
            mangaKey: manga.key,
            chapterKey: chapter.key
        )
        let isDownloaded = await DownloadManager.shared.isChapterDownloaded(chapter: identifier)
        guard isDownloaded else { return false }

        let pages = await DownloadManager.shared.getDownloadedPages(for: identifier)
        for (index, page) in pages.enumerated() {
            guard let image = await loadImage(for: page) else { continue }
            let imageIndex = index
            if ImageTranslationCache.imageURL(
                sourceKey: manga.sourceKey,
                mangaKey: manga.key,
                chapterKey: chapter.key,
                pageIndex: imageIndex,
                settings: settings
            ).exists {
                continue
            }
            do {
                let translated = try await translator.translate(image: image, settings: settings)
                _ = try ImageTranslationCache.store(
                    image: translated,
                    sourceKey: manga.sourceKey,
                    mangaKey: manga.key,
                    chapterKey: chapter.key,
                    pageIndex: imageIndex,
                    settings: settings
                )
                NotificationCenter.default.post(
                    name: .imageTranslationUpdated,
                    object: ImageTranslationUpdate(
                        sourceKey: manga.sourceKey,
                        mangaKey: manga.key,
                        chapterKey: chapter.key,
                        pageIndex: imageIndex
                    )
                )
            } catch {
                LogManager.logger.error("Image translation failed: \(error)")
                continue
            }
        }
        return true
    }

    func translatedImageURL(for page: Page, mangaKey: String) -> URL? {
        let settings = ImageTranslationSettings.current()
        guard settings.enabled else { return nil }
        return ImageTranslationCache.translatedImageURL(
            for: page,
            mangaKey: mangaKey,
            settings: settings
        )
    }

    func clearCache(manga: AidokuRunner.Manga? = nil) {
        ImageTranslationCache.clearCache(manga: manga)
    }

    private func loadImage(for page: AidokuRunner.Page) async -> PlatformImage? {
        switch page.content {
            case let .image(image):
                return image.image
            case let .url(url, _):
                guard url.isFileURL, let data = try? Data(contentsOf: url) else { return nil }
                return PlatformImage(data: data)
            case let .zipFile(url, filePath):
                return loadImageFromArchive(archiveURL: url, filePath: filePath)
            case .text:
                return nil
        }
    }

    private func loadImageFromArchive(archiveURL: URL, filePath: String) -> PlatformImage? {
        do {
            let archive = try Archive(url: archiveURL, accessMode: .read)
            guard let entry = archive[filePath] else { return nil }
            var imageData = Data()
            _ = try archive.extract(entry, consumer: { data in
                imageData.append(data)
            })
            return PlatformImage(data: imageData)
        } catch {
            return nil
        }
    }
}
