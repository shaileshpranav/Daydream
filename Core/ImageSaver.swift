import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves PNGs to ~/Pictures/CoreMLImageGen with a JSON sidecar (and the same JSON
/// in the PNG description) so any image can be reproduced later.
enum ImageSaver {
    static let folder: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appending(path: "CoreMLImageGen", directoryHint: .isDirectory)
    }()

    static func save(_ image: CGImage, request: GenerationRequest, model: InstalledModel, seconds: Double) throws -> GenerationRecord {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = Date()
        let stamp = date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                             timeZone: .current, calendar: .current))
        let fileName = "\(stamp)-\(request.seed).png"
        let record = GenerationRecord(fileName: fileName, request: request, modelID: model.id,
                                      modelName: model.name, date: date, seconds: seconds)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(record)

        let url = folder.appending(path: fileName)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: String(decoding: json, as: UTF8.self)]
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        try json.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        return record
    }

    static func loadRecords() -> [GenerationRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(GenerationRecord.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: folder.appending(path: $0.fileName).path) }
            .sorted { $0.date > $1.date }
    }

    /// Gallery thumbnails, kept so scrolling back doesn't decode 1024-px PNGs again.
    private static let thumbnails: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 600
        return cache
    }()

    static func thumbnail(for record: GenerationRecord, maxPixels: Int = 384) -> CGImage? {
        let key = "\(record.fileName)@\(maxPixels)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let url = folder.appending(path: record.fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    static func delete(_ record: GenerationRecord) {
        let url = folder.appending(path: record.fileName)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: url.deletingPathExtension().appendingPathExtension("json"), resultingItemURL: nil)
    }
}
