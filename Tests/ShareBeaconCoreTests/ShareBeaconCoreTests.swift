import Foundation
import Testing
@testable import ShareBeaconCore

@Suite("ShareBeacon core")
struct ShareBeaconCoreTests {
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

    @Test("mount table finds an existing mount at a different point")
    func mountTableFindsExistingMountAtDifferentPoint() {
        let output = """
        //user@nas.example.test/data on /Volumes/data (smbfs, nodev, nosuid, mounted by tester)
        """
        let table = MountTable(output: output)

        #expect(table.mountPoint(host: "nas.example.test", share: "data") == "/Volumes/data")
        #expect(table.mountPoint(host: "nas.example.test", share: "missing") == nil)
    }

    @Test("mount table finds a share mounted under a different host form")
    func mountTableFindsShareMountedUnderDifferentHostForm() {
        let output = """
        //mjoe@192.168.8.11/docs on /Volumes/docs (smbfs, nodev, nosuid, mounted by mjoe)
        """
        let table = MountTable(output: output)

        #expect(table.mountPoint(forShareNamed: "docs") == "/Volumes/docs")
        #expect(table.mountPoint(forShareNamed: "missing") == nil)
        #expect(table.mountPoint(host: "192.168.8.11", share: "docs") == "/Volumes/docs")
    }

    @Test("mount table matches a host against its resolved address")
    func mountTableMatchesHostAgainstResolvedAddress() {
        let output = """
        //mjoe@127.0.0.1/docs on /Volumes/docs (smbfs, nodev, nosuid, mounted by mjoe)
        """
        let table = MountTable(output: output)

        #expect(table.mountPoint(host: "localhost", share: "docs") == "/Volumes/docs")
    }

    @Test("mount table matches repeated lookups for the same host")
    func mountTableMatchesRepeatedLookupsForSameHost() {
        let output = """
        //mjoe@nas.example.test/data on /Volumes/data (smbfs, nodev, nosuid, mounted by mjoe)
        """
        let table = MountTable(output: output)

        for _ in 0..<3 {
            #expect(table.mountPoint(host: "NAS.example.test", share: "data") == "/Volumes/data")
        }
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

    @Test("dedicated credential account is the share identifier")
    func dedicatedCredentialAccountIsTheShareIdentifier() {
        let share = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Volumes/data",
            isEnabled: true
        )

        #expect(share.credentialAccount == share.id.uuidString)
        #expect(share.effectiveUsername == "user")
    }

    @Test("shared credential account is normalized host and username")
    func sharedCredentialAccountIsNormalizedHostAndUsername() {
        let share = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "other",
            mountPoint: "/Volumes/data",
            isEnabled: true,
            sharedCredential: SharedCredential(host: "NAS.EXAMPLE.TEST", username: "ubani")
        )

        #expect(share.credentialAccount == "shared:nas.example.test\u{1f}ubani")
        #expect(share.effectiveUsername == "ubani")
    }

    @Test("configuration without newer fields decodes with defaults")
    func configurationWithoutNewerFieldsDecodesWithDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"NAS","host":"nas.example.test",\
        "shareName":"data","username":"user","mountPoint":"/Volumes/data","isEnabled":true}
        """
        let decoded = try JSONDecoder().decode(
            ShareConfiguration.self,
            from: Data(json.utf8)
        )

        #expect(decoded.autoMount)
        #expect(decoded.sharedCredential == nil)
    }

    @Test("shared credential survives an encode and decode round trip")
    func sharedCredentialSurvivesRoundTrip() throws {
        let share = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "ubani",
            mountPoint: "/Volumes/data",
            isEnabled: true,
            sharedCredential: SharedCredential(host: "nas.example.test", username: "ubani")
        )

        let data = try JSONEncoder().encode(share)
        let decoded = try JSONDecoder().decode(ShareConfiguration.self, from: data)

        #expect(decoded.sharedCredential == share.sharedCredential)
    }

    // MARK: - Mount point suggestions

    private let volumes = "/Users/tester/Volumes"

    /// The regression: the field is rewritten on every keystroke, so guarding on
    /// "is it still the default" only allowed the first character through.
    @Test("mount point suggestion follows every keystroke of the share name")
    func suggestionFollowsEveryKeystroke() {
        var current = "~/Volumes"
        var lastSuggested: String?

        for partial in ["d", "do", "doc", "docs"] {
            let next = MountPointSuggestion.suggestion(
                for: partial,
                current: current,
                lastSuggested: lastSuggested,
                defaultDirectory: volumes
            )
            #expect(next == "\(volumes)/\(partial)")
            current = next
            lastSuggested = next
        }

        #expect(current == "\(volumes)/docs")
    }

    @Test("mount point suggestion never overwrites a value the user typed")
    func suggestionRespectsUserInput() {
        let typed = "/Volumes/custom-place"

        let next = MountPointSuggestion.suggestion(
            for: "docs",
            current: typed,
            lastSuggested: nil,
            defaultDirectory: volumes
        )

        #expect(next == typed)
    }

    @Test("mount point suggestion resumes after the user clears their own value")
    func suggestionResumesAfterClearing() {
        #expect(MountPointSuggestion.isEditedByUser(
            current: volumes + "/docs",
            lastSuggested: nil,
            defaultDirectory: volumes
        ))

        #expect(MountPointSuggestion.suggestion(
            for: "docs",
            current: "~/Volumes",
            lastSuggested: nil,
            defaultDirectory: volumes
        ) == "\(volumes)/docs")
    }

    @Test("mount point suggestion holds for a blank share name")
    func suggestionHoldsForBlankName() {
        for placeholder in ["~/Volumes", volumes, volumes + "/"] {
            #expect(MountPointSuggestion.suggestion(
                for: "   ",
                current: placeholder,
                lastSuggested: nil,
                defaultDirectory: volumes
            ) == placeholder)
        }
    }

    @Test("mount point suggestion trims surrounding whitespace from the share name")
    func suggestionTrimsWhitespace() {
        #expect(MountPointSuggestion.suggestion(
            for: "  docs  ",
            current: "~/Volumes",
            lastSuggested: nil,
            defaultDirectory: volumes
        ) == "\(volumes)/docs")
    }
}
