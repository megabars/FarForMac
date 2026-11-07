import Testing
import FarCore

@Suite("LuaFar keyboard input records")
struct FarLuaInputRecordTests {
    @Test("ProcessPanelInput records convert to FAR names and four positional values")
    func panelRecord() {
        let input: FarLuaValue = .table([
            "EventType": .integer(1), "KeyDown": .bool(true), "RepeatCount": .integer(1),
            "VirtualKeyCode": .integer(0x26), "VirtualScanCode": .integer(0),
            "UnicodeChar": .string("\u{F700}"), "ControlKeyState": .integer(0x10)
        ])
        #expect(FarLuaInputRecord.name(of: input) == [.string("ShiftUp")])
        #expect(FarLuaInputRecord.name(of: input, split: true) == [.bool(false), .bool(false), .string("Shift"), .string("Up")])
        let encoded = FarLuaInputRecord.record(named: "ShiftUp")
        #expect(encoded.table?["VirtualKeyCode"] == .integer(0x26))
        #expect(encoded.table?["ControlKeyState"] == .integer(0x110))
        #expect(encoded.table?["Name"] == nil)
        #expect(FarLuaInputRecord.name(of: encoded) == [.string("ShiftUp")])
    }

    @Test("Right modifiers, printable keys, and unknown names retain LuaFar return semantics")
    func validAndInvalidNames() {
        let key = FarLuaInputRecord.record(named: "rCtrlRAltShiftF12")
        #expect(key.table?["VirtualKeyCode"] == .integer(0x7B))
        #expect(key.table?["ControlKeyState"] == .integer(0x15))
        #expect(FarLuaInputRecord.name(of: key, split: true) == [.string("RCtrl"), .string("RAlt"), .string("Shift"), .string("F12")])
        #expect(FarLuaInputRecord.name(of: FarLuaInputRecord.record(named: "A")) == [.string("A")])
        #expect(FarLuaInputRecord.name(of: FarLuaInputRecord.record(named: "Ctrl,")) == [.string("Ctrl,")])
        #expect(FarLuaInputRecord.name(of: FarLuaInputRecord.record(named: "CtrlBackSlash")) == [.string("CtrlBackSlash")])
        #expect(FarLuaInputRecord.record(named: "NoSuchFarKey") == .nilValue)
        #expect(FarLuaInputRecord.name(of: .table(["Name": .string("F12")]), split: true) == [.nilValue])
        #expect(FarLuaInputRecord.name(of: .table(["EventType": .integer(2)])) == [.nilValue])
    }
}
