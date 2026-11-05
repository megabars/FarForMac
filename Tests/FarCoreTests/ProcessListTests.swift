import Foundation
import Testing
@testable import FarCore

@Suite struct ProcessListTests {
    @Test func parsesPathsWithSpacesAndMulticoreCPU() throws {
        let rows = try ProcessList.parse(Data("  42 1 501 230.5 2048 /Applications/My App.app/Contents/MacOS/My App\n7 0 0 0.0 0 kernel_task\n".utf8))
        #expect(rows.count == 2 && rows[0].pid == 42 && rows[0].parentPID == 1)
        #expect(rows[0].name == "My App" && rows[0].residentBytes == 2_097_152 && rows[0].cpuPercent == 230.5)
        #expect(rows[1].pid == 7)
    }
    @Test func rejectsMalformedOverflowAndDuplicateRows() throws {
        for line in ["1 0 0 nan 1 cmd", "1 0 0 -1 1 cmd", "1 0 0 0 9223372036854775807 cmd", "1 0 0 0 -1 cmd", "1 0 0 0 1", "1 0 0 0 1 cmd\n1 0 0 0 1 duplicate"] {
            #expect(throws: (any Error).self) { try ProcessList.parse(Data(line.utf8)) }
        }
        #expect(throws: (any Error).self) { try ProcessList.parse(Data(repeating: 32, count: ProcessList.maximumBytes + 1)) }
    }
    @Test func cancellationDoesNotStartCollection() {
        let token = TransferCancellation(); token.cancel()
        #expect(throws: ViewerError.cancelled) { try ProcessList.snapshot(cancellation: token) }
    }
    @Test func nativeSnapshotIncludesThisProcess() throws {
        let rows = try ProcessList.snapshot()
        #expect(rows.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
        #expect(Set(rows.map(\.pid)).count == rows.count)
    }
}
