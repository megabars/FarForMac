import Foundation
import Testing
@testable import FarCore

@Suite
struct EditorSyntaxTests {
    @Test
    func registrySelectsBuiltinsAndFallback() {
        #expect(EditorSyntaxRegistry.provider(for: "/tmp/Main.SWIFT").id == "swift")
        #expect(EditorSyntaxRegistry.provider(for: "config.json").id == "json")
        #expect(EditorSyntaxRegistry.provider(for: ".zshrc").id == "shell")
        #expect(EditorSyntaxRegistry.provider(for: "launch.sh").id == "shell")
        #expect(EditorSyntaxRegistry.provider(for: "README.txt").id == "plain")
        #expect(EditorSyntaxRegistry.provider(for: "README.txt").highlights(text: "true 42").isEmpty)
    }

    @Test
    func swiftLexingPrioritizesStringsAndNestedComments() {
        let text = "let face = \"🙂 // return\" /* a /* b */ true */\nreturn 42"
        let spans = EditorSyntaxRegistry.provider(for: "x.swift").highlights(text: text)
        let source = text as NSString
        #expect(spans.filter { $0.kind == .keyword }.map { source.substring(with: $0.range) } == ["let", "return"])
        #expect(spans.filter { $0.kind == .string }.map { source.substring(with: $0.range) } == ["\"🙂 // return\""])
        #expect(spans.filter { $0.kind == .comment }.map { source.substring(with: $0.range) } == ["/* a /* b */ true */"])
        #expect(spans.last?.kind == .number)
        #expect(spans.allSatisfy { NSMaxRange($0.range) <= source.length })
        for pair in zip(spans, spans.dropFirst()) { #expect(NSMaxRange(pair.0.range) <= pair.1.range.location) }
    }

    @Test
    func jsonAndShellHaveLiteralStringNumberAndCommentSpans() {
        let json = EditorSyntaxRegistry.provider(for: "x.json").highlights(text: "{\"a\": true, \"b\": -12.5e+2, \"c\": null}")
        #expect(json.filter { $0.kind == .literal }.count == 2)
        #expect(json.filter { $0.kind == .string }.count == 3)
        #expect(json.filter { $0.kind == .number }.count == 1)
        let text = "if true; then echo '# literal'; fi # comment"
        let shell = EditorSyntaxRegistry.provider(for: "x.sh").highlights(text: text)
        #expect(shell.filter { $0.kind == .keyword }.count == 3)
        #expect(shell.filter { $0.kind == .comment }.count == 1)
        #expect(shell.filter { $0.kind == .string }.count == 1)
    }

    @Test
    func nativeProvidersCanOverrideAndHighlighterHasSizeLimit() {
        #expect(EditorSyntaxRegistry.provider(for: "x.swift", additionalProviders: [TestSyntaxProvider()]).id == "test")
        let source = String(repeating: "a", count: EditorSyntaxRegistry.maximumHighlightBytes + 1)
        #expect(EditorSyntaxRegistry.provider(for: "x.swift").highlights(text: source).isEmpty)
        #expect(EditorSyntaxRegistry.provider(for: "x.swift").highlights(text: "\"unterminated🙂").count == 1)
        #expect(EditorSyntaxRegistry.provider(for: "x.swift").highlights(text: "/* unterminated").first?.kind == .comment)
    }
}

private struct TestSyntaxProvider: EditorSyntaxProvider {
    let id = "test"
    let title = "Test"
    func supports(filename: String) -> Bool { filename.hasSuffix(".swift") }
    func highlights(text: String) -> [EditorSyntaxSpan] { [] }
}
