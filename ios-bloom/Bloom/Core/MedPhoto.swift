import SwiftUI
import UIKit

/// Medication photos (pill or box) stored on device.
/// Stage 4 uploads them to the private "medication-photos" bucket under `{pregnancy_id}/`.
enum MedPhotoStore {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MedicationPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func save(_ image: UIImage) -> String? {
        let resized = image.resizedToFit(maxDimension: 1200)
        guard let data = resized.jpegData(compressionQuality: 0.8) else { return nil }
        let filename = UUID().uuidString + ".jpg"
        do {
            try data.write(to: directory.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
            return filename
        } catch {
            return nil
        }
    }

    static func image(_ filename: String) -> UIImage? {
        if let cached = cache.object(forKey: filename as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(filename).path) else { return nil }
        // Thumbnails are small on screen; keep a downscaled copy in memory.
        let thumb = image.resizedToFit(maxDimension: 300)
        cache.setObject(thumb, forKey: filename as NSString)
        return thumb
    }

    static func fileURL(_ filename: String) -> URL { directory.appendingPathComponent(filename) }

    static func exists(_ filename: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(filename).path) }

    /// Stores a photo downloaded from the shared pregnancy under its original name.
    static func write(_ data: Data, as filename: String) {
        cache.removeObject(forKey: filename as NSString)
        try? data.write(to: fileURL(filename), options: [.atomic, .completeFileProtection])
    }

    static func delete(_ filename: String) {
        cache.removeObject(forKey: filename as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    static func deleteAll() {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The round badge for a medication: its photo when there is one, otherwise a pill symbol.
struct MedBadge: View {
    var medication: Medication
    var size: CGFloat = 46
    var fill: Color = Theme.blushSoft
    var faded = false

    var body: some View {
        Group {
            if let filename = medication.photoFilename, let image = MedPhotoStore.image(filename) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    .overlay(Circle().stroke(fill, lineWidth: max(2, size * 0.06)))
            } else {
                Image(systemName: "pills.fill")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(Theme.blushDeep)
                    .frame(width: size, height: size)
                    .background(fill, in: .circle)
            }
        }
        .opacity(faded ? 0.5 : 1)
        .accessibilityHidden(true)
    }
}
