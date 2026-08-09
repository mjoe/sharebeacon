@preconcurrency import CoreServices
import Foundation

@MainActor
protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration, at mountPoint: String?) -> Bool
}
@MainActor
struct FinderSidebarRepairer: FinderSidebarRepairing {
    func restoreFavorite(for share: ShareConfiguration, at mountPoint: String? = nil) -> Bool {
        let path = mountPoint ?? share.normalizedMountPoint
        let mountURL = URL(fileURLWithPath: path, isDirectory: true)
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
        let items = snapshot as NSArray
        guard items.count > 0 else {
            logError("Finder \(label) list has no valid insertion point.")
            return false
        }
        let lastItem = items.lastObject as! LSSharedFileListItem

        var existing: LSSharedFileListItem?
        for item in items {
            let item = item as! LSSharedFileListItem
            var error: Unmanaged<CFError>?
            guard let resolved = LSSharedFileListItemCopyResolvedURL(item, 0, &error)?.takeUnretainedValue() else {
                continue
            }
            if (resolved as URL).standardizedFileURL.path == mountURL.standardizedFileURL.path {
                existing = item
                break
            }
        }

        if let existing {
            guard existing !== lastItem else {
                return true
            }
            let status = LSSharedFileListItemMove(list, existing, lastItem)
            if status != noErr {
                logError("Finder rejected moving the \(label) item to the end (OSStatus \(status)).")
            }
            return status == noErr
        }

        let inserted = LSSharedFileListInsertItemURL(
            list,
            lastItem,
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
