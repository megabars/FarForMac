import Foundation
import Testing
@testable import FarCore

struct FarEditorCoordinatesTests {
    @Test func farPositionsUseUTF16AndPreserveMixedEndings() {
        let source = "🙂a\r\nб\rlast\n"
        let table = FarEditorCoordinates(source)
        #expect(table.lines.count == 4)
        #expect(table.offset(line: 1, column: 3) == 2)
        #expect(table.position(2).column == 3)
        #expect(table.offset(line: 2, column: 1) == 5)
        #expect(table.lines[0].ending.length == 2)
        #expect(table.lines[1].ending.length == 1)
        #expect(table.lines[3].text.length == 0)
        #expect(table.offset(line: 4, column: 2) == nil)
        #expect(FarEditorCoordinates("").offset(line: 1, column: 1) == 0)
    }
}
