@preconcurrency import CoreServices
import Foundation

enum SnapshotFailure: Error {
    case unreadable
}

@MainActor
protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration, at mountPoint: String?) -> Bool
}
@MainActor
struct FinderSidebarRepairer: FinderSidebarRepairing {
    func restoreFavorite(for share: ShareConfiguration, at mountPoint: String? = nil) -> Bool {
        let path = mountPoint ?? share.normalizedMountPoint
        let mountURL = URL(fileURLWithPath: path, isDirectory: true)
        return restoreFinderFavorite { target in
            restore(
                mountURL: mountURL,
                name: share.name,
                target: target
            )
        }
    }

    private func restore(
        mountURL: URL,
        name: String,
        target: FinderFavoriteTarget
    ) -> Bool {
        let listType: CFString
        let label: String
        switch target {
        case .volumes:
            listType = kLSSharedFileListFavoriteVolumes.takeUnretainedValue()
            label = "Favorite Volumes"
        case .items:
            listType = kLSSharedFileListFavoriteItems.takeUnretainedValue()
            label = "Favorites"
        }
        return restore(mountURL: mountURL, name: name, listType: listType, label: label)
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

        let mountPath = mountURL.standardizedFileURL.path
        guard case .success(let items) = snapshot(of: list, label: label) else {
            return false
        }

        let candidates = items.map { candidate(for: $0) }
        let plan = finderFavoritePlan(candidates: candidates, mountPath: mountPath)

        switch plan {
        case .removeDuplicates(let drop):
            for index in drop {
                let status = LSSharedFileListItemRemove(list, items[index])
                if status != noErr {
                    logError("Finder rejected removing a duplicate \(label) item (OSStatus \(status)).")
                }
            }
            return true

        case .insertNew:
            // Insert after the last real entry. `kLSSharedFileListItemLast`
            // reads like the natural anchor, but it is the pointer 0x2 and not
            // a CF object. Swift retains a CF parameter on the way in, so the
            // constant crashes the app with EXC_BAD_ACCESS at 0x2.
            guard let lastItem = items.last else {
                logError("Finder \(label) list has no valid insertion point.")
                return false
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

    private func snapshot(of list: LSSharedFileList, label: String) -> Result<[LSSharedFileListItem], SnapshotFailure> {
        var seed: UInt32 = 0
        guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeUnretainedValue() else {
            logError("Could not read Finder \(label) list.")
            return .failure(.unreadable)
        }
        return .success(snapshot as! [Any] as! [LSSharedFileListItem])
    }

    private func candidate(for item: LSSharedFileListItem) -> FinderFavoriteCandidate {
        FinderFavoriteCandidate(resolvedPath: resolvedPath(of: item))
    }

    private func resolvedPath(of item: LSSharedFileListItem) -> String? {
        var error: Unmanaged<CFError>?
        let resolved = LSSharedFileListItemCopyResolvedURL(item, 0, &error)?
            .takeUnretainedValue() as URL?
        return resolved?.standardizedFileURL.path
    }
}
