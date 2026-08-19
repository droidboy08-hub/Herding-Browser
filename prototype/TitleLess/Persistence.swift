import UIKit

/// Page snapshots for the tab grid, cached on disk as JPEGs keyed by tab id.
/// Lives in Caches (regenerable — the system may evict it under pressure).
enum SnapshotStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func url(for id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).jpg")
    }

    static func save(_ image: UIImage, for id: UUID) {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url(for: id), options: .atomic)
        }
    }

    static func load(for id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return UIImage(data: data)
    }

    static func delete(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Drop snapshots whose tabs no longer exist.
    static func prune(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files {
            let name = (file as NSString).deletingPathExtension
            if let id = UUID(uuidString: name), !ids.contains(id) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }
}
