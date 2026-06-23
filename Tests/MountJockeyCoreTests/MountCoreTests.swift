import XCTest
@testable import MountJockeyCore

final class MountCoreTests: XCTestCase {
    func testDefaultShareUsesGenericSMBEndpointAndHomeMountPoint() {
        let share = ShareConfiguration.defaultShare(homeDirectory: "/Users/tester")

        XCTAssertEqual(share.host, "nas.taila7f773.ts.net")
        XCTAssertEqual(share.shareName, "data")
        XCTAssertEqual(share.username, "ubani")
        XCTAssertEqual(share.mountPoint, "/Users/tester/Volumes/data")
        XCTAssertTrue(share.isEnabled)
    }

    func testConfigurationEncodingNeverContainsPassword() throws {
        let share = ShareConfiguration(
            name: "NAS Data",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/Users/tester/Volumes/data",
            isEnabled: true
        )

        let encoded = try JSONEncoder().encode([share])
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
        XCTAssertTrue(json.contains("nas.example.test"))
    }

    func testMountTableMatchesDecodedMountPointAndShare() {
        let output = """
        //ubani@nas.taila7f773.ts.net/data on /Users/tester/Volumes/data (smbfs, nodev, nosuid, mounted by tester)
        """
        let table = MountTable(output: output)

        XCTAssertTrue(table.isMounted(
            host: "nas.taila7f773.ts.net",
            share: "data",
            at: "/Users/tester/Volumes/data"
        ))
    }

    func testMountTableHandlesEscapedSpaces() {
        let output = """
        //user@server/Team%20Data on /Users/tester/Volumes/Team Data (smbfs, nodev, nosuid)
        """
        let table = MountTable(output: output)

        XCTAssertTrue(table.isMounted(
            host: "server",
            share: "Team Data",
            at: "/Users/tester/Volumes/Team Data"
        ))
    }

    func testSMBURLContainsNoCredentialMaterial() throws {
        let share = ShareConfiguration(
            name: "NAS",
            host: "nas.example.test",
            shareName: "data",
            username: "user",
            mountPoint: "/tmp/data",
            isEnabled: true
        )

        let url = try share.smbURL()

        XCTAssertEqual(url.absoluteString, "smb://nas.example.test/data")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
    }

    func testValidationRejectsDuplicateMountPoints() {
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

        XCTAssertThrowsError(try ShareConfiguration.validate([first, second]))
    }
}
