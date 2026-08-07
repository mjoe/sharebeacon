@preconcurrency import CoreServices
import Foundation

protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration) -> Bool
}

struct FinderSidebarRepairer: FinderSidebarRepairing {
    func restoreFavorite(for share: ShareConfiguration) -> Bool {
        let mountURL = URL(fileURLWithPath: share.normalizedMountPoint, isDirectory: true)
        let volumeResult = restore(
            mountURL: mountURL,
            name: share.name,
            listType: kLSSharedFileListFavoriteVolumes.takeUnretainedValue(),
            label: "Favorite Volumes"
        )
        let itemResult = restore(
            mountURL: mountURL,
            name: share.name,
            listType: kLSSharedFileListFavoriteItems.takeUnretainedValue(),
            label: "Favorites"
        )
        return volumeResult || itemResult
    }

    private func restore(
        mountURL: URL,
        name: String,
        listType: CFString,
        label: String
    ) -> Bool {
        guard let list = LSSharedFileListCreate(nil, listType, nil)?.takeUnretainedValue() else {
            logError("Could not open Finder \(label) list.")
            return false
        }

        var seed: UInt32 = 0
        guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeUnretainedValue() else {
            logError("Could not read Finder \(label) list.")
            return false
        }
        let snapshotArray = snapshot as NSArray
        guard snapshotArray.count > 0 else {
            logError("Finder \(label) list has no valid insertion point.")
            return false
        }
        let insertionPoint = snapshotArray.lastObject as! LSSharedFileListItem

        for item in snapshot as NSArray {
            let item = item as! LSSharedFileListItem
            var error: Unmanaged<CFError>?
            guard let resolved = LSSharedFileListItemCopyResolvedURL(item, 0, &error)?.takeUnretainedValue() else {
                continue
            }
            if (resolved as URL).standardizedFileURL.path == mountURL.standardizedFileURL.path {
                return false
            }
        }

        let inserted = LSSharedFileListInsertItemURL(
            list,
            insertionPoint,
            name as CFString,
            nil,
            mountURL as CFURL,
            nil,
            nil
        ) != nil
        if !inserted {
            logError("Finder rejected the \(label) insertion.")
        }
        return inserted
    }
}
