import Foundation
import Testing
@testable import IMMVault

@Suite struct SyncedFolderDetectorTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private func synced(_ path: String) -> Bool {
        SyncedFolderDetector.isSynced(URL(fileURLWithPath: path, isDirectory: true), homeDirectory: home)
    }

    @Test func iCloudDrive() {
        #expect(synced("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/Finance"))
        #expect(synced("/Users/tester/Library/Mobile Documents"))
    }

    @Test func fileProviderFolders() {
        #expect(synced("/Users/tester/Library/CloudStorage/OneDrive-Personal/Docs"))
        #expect(synced("/Users/tester/Library/CloudStorage/GoogleDrive-me@example.com"))
    }

    @Test func dropbox() {
        #expect(synced("/Users/tester/Dropbox/x"))
        #expect(synced("/Users/tester/Dropbox"))
        #expect(!synced("/Users/tester/Documents/Dropbox"))
        #expect(!synced("/Users/tester/DropboxNot/x"))
    }

    @Test func plainFolders() {
        #expect(!synced("/Users/tester/Documents"))
        #expect(!synced("/Users/tester/Documents/Finance"))
        #expect(!synced("/Volumes/External/Finance"))
    }

    @Test func realHomeIsNotEmpty() {
        #expect(!SyncedFolderDetector.realHomeDirectory.path.isEmpty)
    }
}
