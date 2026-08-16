import Foundation
import SnapshotTesting
import Testing

@Suite(.serialized, .snapshots(SnapshotTestSupport.configuration)) struct SnapshotTests {}

enum SnapshotTestSupport {
    #if os(iOS)
    static var supportsPhoneSnapshots: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") != true
    }
    #endif

    static var configuration: SnapshotTestingConfiguration {
        SnapshotTestingConfiguration(
            record: ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" ? .all : .missing,
            snapshotNaming: .testName,
            referenceStorage: .directory("__Snapshots__", relativeTo: .testTarget)
        )
    }
}
