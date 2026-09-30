import Foundation

/// Removes files the previous account left in shared containers (downloaded OG images,
/// staged share-extension uploads, saved agent chats, the recent-summaries cache used by the
/// iMessage app).
public enum SharedLogoutPurger {
    public static let sharedDirectories = ["SharedImages", "Uploads", "Cache", "Chats"]

    public static func purge(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: SharedImageCache.temporaryDirectory)
        SummaryAssetLoader.clearImageCache()
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SummaryIdentifiers.appGroupIdentifier
        ) else { return }
        for directory in sharedDirectories {
            try? fileManager.removeItem(at: container.appending(path: directory, directoryHint: .isDirectory))
        }
        RecentSummariesCache.clear()
    }
}
