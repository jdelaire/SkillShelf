import Foundation
import Testing
@testable import SkillShelf
@testable import SkillShelfCore

@MainActor
struct PromptTextViewTests {
    @Test func markdownRendersAndPreservesOriginalCopyText() async {
        let text = "# Instructions\n\nUse **Swift**.\n"
        let parsed = await PromptTextView.parse(.markdown(text))

        guard case .rendered(let copied, let content) = parsed else {
            Issue.record("Expected rendered markdown")
            return
        }
        #expect(copied == text)
        #expect(content.renderHTML().contains("<h1>Instructions</h1>"))
        #expect(content.renderHTML().contains("<strong>Swift</strong>"))
    }

    @Test(arguments: [
        "prompt = \"Use Swift\"",
        "```\n# Still code\n```",
        "``````\n# Still code\n~~~~~~",
    ])
    func codeStaysInOneBlockAndCopiesWithoutFences(text: String) async {
        let parsed = await PromptTextView.parse(.code(text, language: "toml"))

        guard case .rendered(let copied, let content) = parsed else {
            Issue.record("Expected rendered code")
            return
        }
        let html = content.renderHTML()
        #expect(copied == text)
        #expect(content.renderPlainText() == text)
        #expect(html.components(separatedBy: "<pre>").count == 2)
        #expect(html.contains("<code class=\"language-toml\">"))
        #expect(!html.contains("<h1>"))
    }

    @Test func failureHasNoCopyableText() async {
        let parsed = await PromptTextView.parse(.failed("Could not read prompt"))

        guard case .failed(let reason) = parsed else {
            Issue.record("Expected prompt failure")
            return
        }
        #expect(reason == "Could not read prompt")
        #expect(parsed.text == nil)
    }
}
