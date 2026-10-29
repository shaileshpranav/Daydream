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
        try write(image, record: record)
        return record
    }

    /// Saves an upscaled copy of `original` as a new picture, named after it (e.g.
    /// "…-42-4x.png"), with the original's settings so it can be remade.
    static func saveUpscaled(_ image: CGImage, from original: GenerationRecord, scale: Int,
                             seconds: Double) throws -> GenerationRecord {
        let stem = (original.fileName as NSString).deletingPathExtension
        let fileName = unusedName("\(stem)-\(scale)x")
        var record = GenerationRecord(fileName: fileName, request: original.request, modelID: original.modelID,
                                      modelName: original.modelName, date: Date(), seconds: original.seconds)
        record.upscale = UpscaleInfo(scale: scale, source: original.fileName, model: Upscaler.modelName, seconds: seconds)
        try write(image, record: record)
        return record
    }

    /// Saves a picture from the Edit section. `record` is filled in with a file name based on
    /// `stem` ("…-edit.png"); everything else describing the picture comes from the caller.
    static func saveEdited(_ image: CGImage, stem: String, record: (String) -> GenerationRecord) throws -> GenerationRecord {
        let saved = record(unusedName("\(stem)-edit"))
        try write(image, record: saved)
        return saved
    }

    /// "<stem>.png", or "<stem>-2.png" and so on if that's taken.
    private static func unusedName(_ stem: String) -> String {
        var fileName = "\(stem).png"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: fileName).path) {
            fileName = "\(stem)-\(n).png"
            n += 1
        }
        return fileName
    }

    /// A saved picture's size, read from its file's header without decoding it.
    static func pixelSize(of record: GenerationRecord) -> CGSize? {
        let url = folder.appending(path: record.fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Writes the PNG, with the record in its description, and the record as JSON beside it.
    private static func write(_ image: CGImage, record: GenerationRecord) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = record.fileName
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
    }

    /// Every saved record, newest first. Reads one JSON file per image, so it runs off the
    /// main thread: with a few hundred pictures it would otherwise stall opening Create or
    /// My Pictures.
    static func loadRecords() async -> [GenerationRecord] {
        await Task.detached(priority: .userInitiated) { readRecords() }.value
    }

    private static func readRecords() -> [GenerationRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // The directory listing already says which PNGs exist: no stat per record.
        let images = Set(files.lazy.filter { $0.pathExtension == "png" }.map(\.lastPathComponent))
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(GenerationRecord.self, from: Data(contentsOf: $0)) }
            .filter { images.contains($0.fileName) }
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

    /// Moves the picture and its settings file to the Trash. Throws when the picture can't be
    /// moved, so callers keep showing it; a picture already gone from the folder counts as done.
    static func delete(_ record: GenerationRecord) throws {
        let fm = FileManager.default
        let url = folder.appending(path: record.fileName)
        if fm.fileExists(atPath: url.path) {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw RuntimeError("Couldn't move \(record.fileName) to the Trash: \(error.localizedDescription)")
            }
        }
        // Without its picture the settings file is useless, so a failure here isn't reported.
        try? fm.trashItem(at: url.deletingPathExtension().appendingPathExtension("json"), resultingItemURL: nil)
    }
}
