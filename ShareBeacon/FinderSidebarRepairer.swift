import Foundation

protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration) -> Bool
}

struct FinderSidebarRepairer: FinderSidebarRepairing {
    private var applicationID: CFString { "com.apple.sidebarlists" as CFString }
    private var favoritesKey: CFString { "favorites" as CFString }

    func restoreFavorite(for share: ShareConfiguration) -> Bool {
        let url = URL(fileURLWithPath: share.normalizedMountPoint, isDirectory: true)
        guard let bookmark = try? url.bookmarkData(
            options: [.suitableForBookmarkFile],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return false
        }

        var root = (CFPreferencesCopyAppValue(favoritesKey, applicationID) as? [String: Any]) ?? [:]
        var items = root["items"] as? [[String: Any]] ?? []

        guard !items.contains(where: { item in
            guard let existingBookmark = item["Bookmark"] as? Data else { return false }
            var isStale = false
            guard let existingURL = try? URL(
                resolvingBookmarkData: existingBookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return false
            }
            return existingURL.standardizedFileURL.path == url.standardizedFileURL.path
        }) else {
            return false
        }

        items.append([
            "Name": url.lastPathComponent,
            "Bookmark": bookmark,
            "CustomItemProperties": [
                "com.apple.LSSharedFileList.BindingURL": bookmark
            ]
        ])
        root["items"] = items

        CFPreferencesSetAppValue(
            favoritesKey,
            root as NSDictionary,
            applicationID
        )
        return CFPreferencesAppSynchronize(applicationID)
    }
}
