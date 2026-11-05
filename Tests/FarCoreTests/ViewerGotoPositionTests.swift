import Testing
import FarCore

struct ViewerGotoPositionTests {
    @Test func acceptsFARPositionSyntax() throws {
        for hex in ["0x20", "$20", "20h"] {
            #expect(try ViewerGotoPosition(hex, hexadecimal: false, offset: 4, fileSize: 1_000).offset == 32)
        }
        #expect(try ViewerGotoPosition("32m", hexadecimal: true, offset: 4, fileSize: 1_000).offset == 32)
        #expect(try ViewerGotoPosition("20", hexadecimal: true, offset: 4, fileSize: 1_000).offset == 32)
        #expect(try ViewerGotoPosition("+50%", hexadecimal: false, offset: 20, fileSize: 100).offset == 70)
        #expect(try ViewerGotoPosition("-50%", hexadecimal: false, offset: 20, fileSize: 100).offset == 0)
        #expect(try ViewerGotoPosition("200", hexadecimal: false, offset: 20, fileSize: 100).offset == 100)
    }

    @Test func preservesMissingCoordinatesAndUsesZeroBasedColumns() throws {
        let columnOnly = try ViewerGotoPosition(",+10", hexadecimal: false, offset: 9, fileSize: 100, visibleColumn: 12)
        #expect(columnOnly.offset == 9 && columnOnly.column == 22)
        let positionOnly = try ViewerGotoPosition("+2,", hexadecimal: false, offset: 9, fileSize: 100, visibleColumn: 12)
        #expect(positionOnly.offset == 11 && positionOnly.column == nil)
        #expect(try ViewerGotoPosition("$20,40", hexadecimal: false, offset: 9, fileSize: 100, visibleColumn: 12).column == 40)
        #expect(try ViewerGotoPosition("$20,40", hexadecimal: false, offset: 9, fileSize: 100).column == nil)
        #expect(throws: EditorEditingError.invalidPosition) {
            try ViewerGotoPosition("0x,20", hexadecimal: false, offset: 9, fileSize: 100)
        }
    }
}
