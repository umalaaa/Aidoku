//
//  TranslatedImagesView.swift
//  Aidoku
//
//  Created by Jules on 10/26/24.
//

import SwiftUI

struct TranslatedImagesView: View {
    @State private var images: [URL] = []

    var body: some View {
        List {
            ForEach(images, id: \.self) { url in
                HStack {
                    if let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Rectangle()
                            .fill(Color.gray)
                            .frame(width: 50, height: 50)
                    }

                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .font(.body)
                        if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
                           let size = attr[.size] as? Int64 {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: deleteImages)
        }
        .navigationTitle(NSLocalizedString("TRANSLATED_IMAGES"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(NSLocalizedString("CLEAR_ALL")) {
                    clearAll()
                }
            }
        }
        .onAppear {
            loadImages()
        }
    }

    private func loadImages() {
        images = ImageTranslator.shared.getCachedImages()
    }

    private func deleteImages(at offsets: IndexSet) {
        offsets.forEach { index in
            let url = images[index]
            ImageTranslator.shared.deleteCachedImage(url: url)
        }
        images.remove(atOffsets: offsets)
    }

    private func clearAll() {
        ImageTranslator.shared.clearCache()
        images = []
    }
}
