import Foundation
import Testing
@testable import FarCore

@Suite struct TerminalInputTests {
    @Test func xtermFunctionNavigationAndKeypadBytes() {
        let escape = "\u{1b}"
        let expected = ["OP", "OQ", "OR", "OS", "[15~", "[17~", "[18~", "[19~", "[20~", "[21~", "[23~", "[24~"]
        for (index, code) in expected.enumerated() {
            #expect(TerminalInput.encode(.function(index + 1)) == Data((escape + code).utf8))
        }
        #expect(TerminalInput.encode(.function(5), modifiers: [.control, .shift, .option]) == Data("\u{1b}[15;8~".utf8))
        #expect(TerminalInput.encode(.function(2), modifiers: [.control]) == Data("\u{1b}[1;5Q".utf8))
        #expect(TerminalInput.encode(.up, applicationCursor: true) == Data("\u{1b}OA".utf8))
        #expect(TerminalInput.encode(.home, modifiers: [.option], applicationCursor: true) == Data("\u{1b}[1;3H".utf8))
        #expect(TerminalInput.encode(.tab, modifiers: [.shift]) == Data("\u{1b}[Z".utf8))
        #expect(TerminalInput.encode(.insert) == Data("\u{1b}[2~".utf8))
        #expect(TerminalInput.encode(.keypad("8"), applicationKeypad: true) == Data("\u{1b}Ox".utf8))
        #expect(TerminalInput.encode(.keypad("8")) == Data([56]))
        #expect(TerminalInput.encode(.control(3), modifiers: [.option]) == Data([27, 3]))
    }

    @Test func mouseTrackingRespectsModesCoordinatesAndEncoding() {
        var screen = TerminalScreen()
        #expect(screen.mouseReporting.encode(.press(.left), column: 1, row: 1) == nil)
        screen.append("\u{1b}[?9h")
        #expect(screen.mouseReporting.encode(.press(.right), column: 2, row: 3, modifiers: [.control]) == Data([27, 91, 77, 34, 34, 35]))
        #expect(screen.mouseReporting.encode(.release(.right), column: 2, row: 3) == nil)
        screen.append("\u{1b}[?1002;1006h")
        #expect(screen.mouseReporting.encode(.move(nil), column: 10, row: 20) == nil)
        #expect(screen.mouseReporting.encode(.move(.left), column: 10, row: 20, modifiers: [.shift, .control]) == Data("\u{1b}[<52;10;20M".utf8))
        #expect(screen.mouseReporting.encode(.release(.right), column: 2, row: 3) == Data("\u{1b}[<2;2;3m".utf8))
        #expect(screen.mouseReporting.encode(.scroll(.wheelDown), column: 2, row: 3) == Data("\u{1b}[<65;2;3M".utf8))
        screen.append("\u{1b}[?1003;1016h\u{1b}[?1002;1006l")
        #expect(screen.mouseReporting.encode(.move(nil), column: 2, row: 3, pixelX: 16, pixelY: 35) == Data("\u{1b}[<35;16;35M".utf8))
        screen.append("\u{1b}[?1005h")
        #expect(screen.mouseReporting.encode(.press(.left), column: 500, row: 1) == Data([27, 91, 77, 32, 0xC8, 0x94, 33]))
        screen.append("\u{1b}[?1015h")
        #expect(screen.mouseReporting.encode(.release(.left), column: 100, row: 1) == Data("\u{1b}[35;100;1M".utf8))
        screen.append("\u{1b}[?1015l")
        #expect(screen.mouseReporting.encode(.press(.left), column: 224, row: 1) == nil)
    }
}
