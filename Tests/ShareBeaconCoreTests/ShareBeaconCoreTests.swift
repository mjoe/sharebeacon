import Testing
@testable import ShareBeaconCore

@Suite("ShareBeacon core")
struct ShareBeaconCoreTests {
    @Test("default share uses generic SMB endpoint and home mount point")
    func defaultShareUsesGenericSMBEndpointAndHomeMountPoint() {
        let share = ShareConfiguration.defaultShare(homeDirectory: "/Users/tester")

        #expect(share.host == "nas.taila7f773.ts.net")
        #expect(share.shareName == "data")
        #expect(share.username == "ubani")
        #expect(share.mountPoint == "/Users/tester/Volumes/data")
        #expect(share.isEnabled)
    }

    @Test("configuration encoding never contains a password")
    func configurationEncodingNeverContainsPassword() throws {
        let share = ShareConfiguration(
            name: "NAS Data",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/data",
            isEnabled: true
        )

        let encoded = try JSONEncoder().encode([share])
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(!json.localizedCaseInsensitiveContains("password"))
        #expect(json.contains("nas.example.test"))
    }

    @Test("mount table matches decoded mount point and share")
    func mountTableMatchesDecodedMountPointAndShare() {
        let output = """
        //ubani@nas.taila7f773.ts.net/data on /Users/tester/Volumes/data (smbfs, nodev, nosuid, mounted by tester)
        """
        let table = MountTable(output: output)

        #expect(table.isMounted(
            host: "nas.taila7f773.ts.net",
            share: "data",
            at: "/Users/tester/Volumes/data"
        ))
    }

    @Test("mount table handles escaped spaces")
    func mountTableHandlesEscapedSpaces() {
        let output = """
        //user@server/Team%20Data on /Users/tester/Volumes/Team Data (smbfs, nodev, nosuid)
        """
        let table = MountTable(output: output)

        #expect(table.isMounted(
            host: "server",
            share: "Team Data",
            at: "/Users/tester/Volumes/Team Data"
        ))
    }

    @Test("SMB URL contains no credential material")
    func smbURLContainsNoCredentialMaterial() throws {
        let share = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/tmp/data",
            isEnabled: true
        )

        let url = try share.smbURL()

        #expect(url.absoluteString == "smb://nas.example.test/data")
        #expect(url.user == nil)
        #expect(url.password == nil)
    }

    @Test("validation rejects duplicate mount points")
    func validationRejectsDuplicateMountPoints() {
        let first = ShareConfiguration(
            name: "One",
            host: "one.test",
            shareName: "data",
            username: "a",
            mountPoint: "/tmp/shared",
            isEnabled: true
        )
        let second = ShareConfiguration(
            name: "Two",
            host: "two.test",
            shareName: "data",
            username: "b",
            mountPoint: "/tmp/shared",
            isEnabled: true
        )

        #expect(throws: ShareBeaconError.self) {
            try ShareConfiguration.validate([first, second])
        }
    }

    @Test("mount identity changes when endpoint or path changes")
    func mountIdentityChangesWhenEndpointOrPathChanges() {
        let original = ShareConfiguration(
            name: "NAS",
            host: "NAS.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "~/Volumes/data",
            isEnabled: true
        )
        var changed = original
        changed.host = "other.example.test"

        #expect(original.mountIdentity != changed.mountIdentity)
    }
}
