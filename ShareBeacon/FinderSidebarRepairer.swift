import Foundation

protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration) -> Bool
}

struct FinderSidebarRepairer: FinderSidebarRepairing {
    private var sharedFileListURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
            .appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems.sfl4")
    }

    func restoreFavorite(for share: ShareConfiguration) -> Bool {
        let url = URL(fileURLWithPath: share.normalizedMountPoint, isDirectory: true)
        guard let bookmark = try? url.bookmarkData(
            options: [.suitableForBookmarkFile],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return false
        }

        let fileManager = FileManager.default
        let root: NSMutableDictionary
        if let data = try? Data(contentsOf: sharedFileListURL),
           let decoded = try? NSKeyedUnarchiver.unarchivedObject(
               ofClasses: [NSDictionary.self, NSArray.self, NSData.self, NSString.self, NSNumber.self],
               from: data
           ) as? NSDictionary,
           let copy = decoded.mutableCopy() as? NSMutableDictionary {
            root = copy
        } else {
            root = [
                "items": NSMutableArray(),
                "properties": NSMutableDictionary()
            ]
        }

        let items = (root["items"] as? NSArray)?.mutableCopy() as? NSMutableArray ?? NSMutableArray()
        for case let item as NSDictionary in items {
            guard let existingBookmark = item["Bookmark"] as? Data else { continue }
            var isStale = false
            guard let existingURL = try? URL(
                resolvingBookmarkData: existingBookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            if existingURL.standardizedFileURL.path == url.standardizedFileURL.path {
                return false
            }
        }

        items.add([
            "Bookmark": bookmark,
            "CustomItemProperties": [
                "com.apple.finder.dontshowonreappearance": true,
                "com.apple.LSSharedFileList.ItemIsHidden": false
            ],
            "uuid": UUID().uuidString,
            "visibility": 0
        ])
        root["items"] = items

        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: root,
            requiringSecureCoding: false
        ) else {
            return false
        }

        do {
            try fileManager.createDirectory(
                at: sharedFileListURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: sharedFileListURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
