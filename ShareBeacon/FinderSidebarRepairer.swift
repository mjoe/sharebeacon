@preconcurrency import CoreServices
import Foundation

protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration) -> Bool
}

struct FinderSidebarRepairer: FinderSidebarRepairing {
    func restoreFavorite(for share: ShareConfiguration) -> Bool {
        guard let list = LSSharedFileListCreate(
            nil,
            kLSSharedFileListFavoriteVolumes.takeUnretainedValue(),
            nil
        )?.takeUnretainedValue() else {
            logError("Could not open Finder Favorite Volumes list.")
            return false
        }

        var seed: UInt32 = 0
        guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeUnretainedValue() else {
            logError("Could not read Finder Favorite Volumes list.")
            return false
        }

        let mountURL = URL(fileURLWithPath: share.normalizedMountPoint, isDirectory: true)
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
            kLSSharedFileListItemLast.takeUnretainedValue(),
            share.name as CFString,
            nil,
            mountURL as CFURL,
            nil,
            nil
        ) != nil
        if !inserted {
            logError("Finder rejected the Favorite Volumes insertion.")
        }
        return inserted
    }
}
