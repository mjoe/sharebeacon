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
        #expect(decoded.favoritePreference == .followGeneral)
        #expect(decoded.restoresFavorite(generalDefault: true))
        #expect(decoded.restoresFavorite(generalDefault: false) == false)
    }

    @Test("share without a favorite preference follows the general default")
    func favoritePreferenceFollowsGeneralDefault() {
        let share = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Volumes/data",
            isEnabled: true
        )

        #expect(share.favoritePreference == .followGeneral)
        #expect(share.restoresFavorite(generalDefault: true))
        #expect(share.restoresFavorite(generalDefault: false) == false)
    }

    @Test("share favorite preference overrides the general default")
    func favoritePreferenceOverridesGeneralDefault() {
        let always = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Volumes/data",
            isEnabled: true,
            favoritePreference: .always
        )
        let never = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Volumes/data",
            isEnabled: true,
            favoritePreference: .never
        )

        #expect(always.restoresFavorite(generalDefault: false))
        #expect(never.restoresFavorite(generalDefault: true) == false)
    }

    @Test("favorite preference survives an encode and decode round trip")
    func favoritePreferenceSurvivesRoundTrip() throws {
        for preference in FinderFavoritePreference.allCases {
            let share = ShareConfiguration(
                name: "NAS",
                host: "nas.example.test",
                shareName: "data",
                username: "user",
                mountPoint: "/Volumes/data",
                isEnabled: true,
                favoritePreference: preference
            )
            let encoded = try JSONEncoder().encode([share])
            let decoded = try JSONDecoder().decode(
                [ShareConfiguration].self,
                from: encoded
            )

            #expect(decoded.first?.favoritePreference == preference)
        }
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

    @Test("finder favorite prefers the volume list over the item list")
    func finderFavoritePrefersVolumeList() {
        #expect(FinderFavoriteTarget.allCases == [.volumes, .items])
    }

    @Test("finder favorite writes only the volume list when it succeeds")
    func finderFavoriteStopsAfterVolumeSuccess() {
        var attempted: [FinderFavoriteTarget] = []

        let restored = restoreFinderFavorite { target in
            attempted.append(target)
            return target == .volumes
        }

        #expect(restored)
        #expect(attempted == [.volumes])
    }

    @Test("finder favorite falls back to the item list when the volume list fails")
    func finderFavoriteFallsBackToItemList() {
        var attempted: [FinderFavoriteTarget] = []

        let restored = restoreFinderFavorite { target in
            attempted.append(target)
            return target == .items
        }

        #expect(restored)
        #expect(attempted == [.volumes, .items])
    }

    @Test("finder favorite reports failure when every list rejects the mount")
    func finderFavoriteFailsWhenEveryListRejects() {
        var attempted: [FinderFavoriteTarget] = []

        let restored = restoreFinderFavorite { target in
            attempted.append(target)
            return false
        }

        #expect(!restored)
        #expect(attempted == [.volumes, .items])
    }

    @Test("finder favorite plan collapses duplicates onto the first entry")
    func planCollapsesDuplicates() {
        let candidates = [
            FinderFavoriteCandidate(resolvedPath: "/Users/tester/Volumes/other"),
            FinderFavoriteCandidate(resolvedPath: "/Users/tester/Volumes/data"),
            FinderFavoriteCandidate(resolvedPath: "/Users/tester/Volumes/data"),
            FinderFavoriteCandidate(resolvedPath: "/Users/tester/Volumes/data")
        ]

        #expect(finderFavoritePlan(
            candidates: candidates,
            mountPath: "/Users/tester/Volumes/data"
        ) == .removeDuplicates([2, 3]))
    }

    @Test("finder favorite plan keeps a single existing entry untouched")
    func planKeepsSingleEntry() {
        let candidates = [
            FinderFavoriteCandidate(resolvedPath: "/Users/tester/Volumes/other"),
            FinderFavoriteCandidate(resolvedPath: "/Users/tester/Volumes/data")
        ]

        #expect(finderFavoritePlan(
            candidates: candidates,
            mountPath: "/Users/tester/Volumes/data"
        ) == .removeDuplicates([]))
    }

    @Test("finder favorite plan inserts when no entry matches")
    func planInsertsWhenNothingMatches() {
        let candidates = [
            FinderFavoriteCandidate(resolvedPath: "/Users/tester/Volumes/other"),
            FinderFavoriteCandidate(resolvedPath: nil)
        ]

        #expect(finderFavoritePlan(
            candidates: candidates,
            mountPath: "/Users/tester/Volumes/data"
        ) == .insertNew)
    }

    @Test("finder favorite plan inserts on an empty list")
    func planInsertsOnEmptyList() {
        #expect(finderFavoritePlan(candidates: [], mountPath: "/Users/tester/Volumes/data") == .insertNew)
    }
}

@Suite("Network link")
struct NetworkLinkTests {
    @Test("interfaces are classified by type, tunnels by name")
    func interfacesAreClassified() {
        #expect(NetworkLink.kind(interfaceName: "en8", systemType: "Ethernet") == .wired)
        #expect(NetworkLink.kind(interfaceName: "en0", systemType: "IEEE80211") == .wifi)
        #expect(NetworkLink.kind(interfaceName: "utun4", systemType: nil) == .tunnel)
        #expect(NetworkLink.kind(interfaceName: "bridge0", systemType: "Bridge") == .other)
    }

    @Test("wired label carries the link speed")
    func wiredLabelCarriesSpeed() {
        #expect(NetworkLink(interfaceName: "en8", kind: .wired, bitsPerSecond: 2_500_000_000).label == "Ethernet 2.5 Gb/s")
        #expect(NetworkLink(interfaceName: "en4", kind: .wired, bitsPerSecond: 1_000_000_000).label == "Ethernet 1 Gb/s")
        #expect(NetworkLink(interfaceName: "en5", kind: .wired, bitsPerSecond: 100_000_000).label == "Ethernet 100 Mb/s")
        #expect(NetworkLink(interfaceName: "en6", kind: .wired, bitsPerSecond: 0).label == "Ethernet")
        #expect(NetworkLink(interfaceName: "en0", kind: .wifi, bitsPerSecond: 0).label == "Wi-Fi")
        #expect(NetworkLink(interfaceName: "en0", kind: .wifi, bitsPerSecond: 1_633_000_000).label == "Wi-Fi 1.6 Gb/s")
    }

    @Test("media subtypes report the negotiated speed")
    func mediaSubtypesReportSpeed() {
        // 10Gbase-T, the port a Mac reports with an unknown baud rate.
        #expect(SystemNetworkLinkResolver.speed(forMediaSubtype: 21) == 10_000_000_000)
        #expect(SystemNetworkLinkResolver.speed(forMediaSubtype: 23) == 5_000_000_000)
        #expect(SystemNetworkLinkResolver.speed(forMediaSubtype: 22) == 2_500_000_000)
        #expect(SystemNetworkLinkResolver.speed(forMediaSubtype: 16) == 1_000_000_000)
        #expect(SystemNetworkLinkResolver.speed(forMediaSubtype: 6) == 100_000_000)
        #expect(SystemNetworkLinkResolver.speed(forMediaSubtype: 0) == nil)
    }

    @Test("an unreported baud rate is not a speed")
    func unreportedBaudRateIsZero() {
        #expect(SystemNetworkLinkResolver.usableBaudRate(UInt64(UInt32.max)) == 0)
        #expect(SystemNetworkLinkResolver.usableBaudRate(10_000_000_000) == 10_000_000_000)
        let link = NetworkLink(
            interfaceName: "en0",
            kind: .wired,
            bitsPerSecond: SystemNetworkLinkResolver.usableBaudRate(UInt64(UInt32.max))
        )
        #expect(link.label == "Ethernet")
    }

    @Test("short link speed fits in a few characters")
    func shortSpeedFitsInFewCharacters() {
        #expect(NetworkLink(interfaceName: "en8", kind: .wired, bitsPerSecond: 2_500_000_000).shortSpeed == "2.5G")
        #expect(NetworkLink(interfaceName: "en4", kind: .wired, bitsPerSecond: 10_000_000_000).shortSpeed == "10G")
        #expect(NetworkLink(interfaceName: "en6", kind: .wired, bitsPerSecond: 100_000_000).shortSpeed == "100M")
        #expect(NetworkLink(interfaceName: "en7", kind: .wired, bitsPerSecond: 0).shortSpeed == nil)
    }

    @Test("a wired expectation flags only a known non-wired link")
    func wiredExpectationFlagsNonWiredLinks() {
        let wifi = NetworkLink(interfaceName: "en0", kind: .wifi, bitsPerSecond: 0)
        let cable = NetworkLink(interfaceName: "en8", kind: .wired, bitsPerSecond: 0)
        #expect(!LinkExpectation.wired.isSatisfied(by: wifi))
        #expect(LinkExpectation.wired.isSatisfied(by: cable))
        #expect(LinkExpectation.wired.isSatisfied(by: nil))
        #expect(LinkExpectation.any.isSatisfied(by: wifi))
    }

    @Test("a stored share without a link expectation accepts any link")
    func storedShareDefaultsToAnyLink() throws {
        let json = """
        [{"id":"8C0E9B5A-4C47-4E0B-9C61-0F6B3C1D2E3F","name":"Data","host":"nas","shareName":"data",
        "username":"user","mountPoint":"/Users/tester/Volumes/data","isEnabled":true}]
        """
        let shares = try JSONDecoder().decode([ShareConfiguration].self, from: Data(json.utf8))
        #expect(shares.first?.linkExpectation == .any)
    }

    @Test("the loopback host resolves to the loopback interface")
    func loopbackResolvesToLoopback() {
        #expect(SystemNetworkLinkResolver().link(toHost: "127.0.0.1")?.interfaceName == "lo0")
    }
}

@Suite("Share status")
struct ShareStatusTests {
    static let multichannelOutput = """
    Session: /Users/tester/Volumes/S$
    Info: Setup Time: 2026-10-19 17:16:22, Multichannel ON: yes, Reconnect Count: 0
    \tTotal RX Bytes: 68954026475 (Packets: 11085429)
    \tTotal TX Bytes: 102567504225 (Packets: 10992981)
           id         client IF             server IF   state                     server ip                 port   speed
    ========================================================================================================================
    M     184  en8    (Ethernet)   19             8 (RSS_0)  [session active       ]   192.168.1.105             445    2.5 Gb
    Server NIC:
    \tname: NA, idx: 8, type:    NA, speed 2.5 Gb, state connected
    \t\tip_addr: 192.168.1.105
    Client NIC:
    \tname: en8, idx: 19, type: wired, speed 2.5 Gb, state connected

    Session: /Users/tester/Volumes/18TB-WD-1
    Info: Setup Time: 2026-10-19 17:16:24, Multichannel ON: no, Reconnect Count: 0
    \tTotal RX Bytes: 2209343886 (Packets: 3992981)
    \tTotal TX Bytes: 2140570790 (Packets: 3992968)
           id         client IF             server IF   state                     server ip                 port   speed
    ========================================================================================================================
    M     140     N/A                          N/A      [session active       ]   192.168.2.49              445    N/A
    """

    @Test("smbutil multichannel output yields sessions, counters and channels")
    func multichannelOutputParses() throws {
        let sessions = SMBSession.parse(Self.multichannelOutput)
        #expect(sessions.count == 2)
        let windows = try #require(sessions.first)
        #expect(windows.mountPath == "/Users/tester/Volumes/S$")
        #expect(windows.receivedBytes == 68_954_026_475)
        #expect(windows.sentBytes == 102_567_504_225)
        #expect(windows.activeChannel == .init(clientInterface: "en8", serverAddress: "192.168.1.105", isActive: true))
        #expect(sessions[1].activeChannel == .init(clientInterface: nil, serverAddress: "192.168.2.49", isActive: true))
    }

    @Test("byte counts are short")
    func bytesAreShort() {
        #expect(ByteFormatting.short(3_200_000_000_000) == "3.2T")
        #expect(ByteFormatting.short(18_000_000_000_000) == "18T")
        #expect(ByteFormatting.short(640_000_000_000) == "640G")
        #expect(ByteFormatting.short(2_000_000_000) == "2G")
    }

    @Test("a reader that misses its deadline returns and ends its child")
    func readerGivesUpOnDeadline() {
        let start = ContinuousClock.now
        let sessions = SMBSessionReader.read(
            timeout: 0.3,
            executable: "/bin/sh",
            arguments: ["-c", "sleep 5"]
        )
        let elapsed = ContinuousClock.now - start
        #expect(sessions.isEmpty)
        #expect(elapsed < .seconds(2))
    }

    @Test("volume usage reports the used fraction and free space")
    func volumeUsageReportsFraction() {
        let usage = VolumeUsage(totalBytes: 18_000_000_000_000, freeBytes: 4_500_000_000_000)
        #expect(usage.usedFraction == 0.75)
        #expect(usage.shortFree == "4.5T")
        #expect(usage.detail == "4.5T free of 18T")
    }

    @Test("sharebeacon links parse into commands")
    func linksParseIntoCommands() throws {
        func command(_ text: String) -> ShareBeaconCommand? {
            URL(string: text).flatMap(ShareBeaconCommand.init(url:))
        }
        #expect(command("sharebeacon://mount-all") == .mount(.all))
        #expect(command("sharebeacon://unmount?host=NAS") == .unmount(.host("NAS")))
        #expect(command("sharebeacon://remount?share=18TB-WD-1") == .remount(.share("18TB-WD-1")))
        #expect(command("sharebeacon://open?share=S$") == .open("S$"))
        #expect(command("sharebeacon://settings") == .settings)
        #expect(command("sharebeacon://mount") == nil)
        #expect(command("https://mount-all") == nil)
    }

    @Test("a command target matches shares by name, share name or host")
    func commandTargetsMatchShares() {
        let share = ShareConfiguration(
            name: "Data", host: "NAS", shareName: "data-share", username: "u",
            mountPoint: "/Users/tester/Volumes/data", isEnabled: true
        )
        #expect(ShareBeaconCommand.matches(.share("data"), share))
        #expect(ShareBeaconCommand.matches(.share("DATA-SHARE"), share))
        #expect(ShareBeaconCommand.matches(.host("nas"), share))
        #expect(!ShareBeaconCommand.matches(.host("nas2"), share))
    }

    @Test("a probe of a local folder reports its usage")
    func localProbeReportsUsage() {
        guard case .usage(let usage) = VolumeProber.probe(path: NSTemporaryDirectory()) else {
            Issue.record("expected usage")
            return
        }
        #expect(usage.totalBytes > 0)
    }
}
