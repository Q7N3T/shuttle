import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum ImageConvert {
    /// HEIC → JPG рядом с исходником; исходник удаляется. Дата изменения сохраняется.
    @discardableResult
    static func heicToJPEG(_ url: URL, quality: Double = 0.9) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw MTPError.failed(L("Не удалось прочитать %@", url.lastPathComponent))
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let out = uniqueURL(url.deletingPathExtension().appendingPathExtension("jpg"))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MTPError.failed(L("Не удалось создать JPG"))
        }
        var options = props
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, img, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MTPError.failed(L("Не удалось сохранить JPG")) }
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: out.path)
        }
        try FileManager.default.removeItem(at: url)
        return out
    }

    /// Все HEIC внутри файла/папки.
    static func convertAllHEIC(in url: URL) -> Int {
        var n = 0
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let files: [URL] = isDir.boolValue
            ? (fm.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            : [url]
        for f in files where ["heic", "heif"].contains(f.pathExtension.lowercased()) {
            if (try? heicToJPEG(f)) != nil { n += 1 }
        }
        return n
    }

    /// Уменьшенная копия для превью.
    static func downsample(_ data: Data, maxPixel: Int = 256) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
