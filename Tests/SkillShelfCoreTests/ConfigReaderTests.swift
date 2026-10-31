import Testing
@testable import SkillShelfCore

@Suite struct ConfigReaderTests {
    @Test(arguments: [#"[profiles."review"]"#, "[profiles.'review']", "[[profiles.review]]", "[profiles.review] trailing"])
    func tomlUnsupportedHeadersSuspendAssignmentsUntilKnownSection(_ header: String) {
        let toml = TOMLKeys("""
        model = "global"
        \(header)
        model = "profile"
        developer_instructions = "profile-only"
        [compat.claude]
        rules = false
        \(header)
        rules = true
        [paths]
        extra_rule_dirs = ["~/rules"]
        """)
        #expect(toml.string("model") == "global")
        #expect(toml.string("developer_instructions") == nil)
        #expect(toml.bool("compat.claude.rules") == false)
        #expect(toml.strings("paths.extra_rule_dirs") == ["~/rules"])
    }

    @Test func tomlReadsStringsBoolsArraysAndMultiline() {
        let toml = TOMLKeys("""
        model = "gpt-6.1-sol"
        developer_instructions = \"\"\"
        Line one
        Say \\"hi\\"\"\"\"
        literal = 'C:\\path'
        [compat.claude]
        skills = false
        [paths]
        extra_rule_dirs = ["~/rules", "/opt/r#x"] # comment
        """)
        #expect(toml.string("model") == "gpt-6.1-sol")
        #expect(toml.string("developer_instructions") == "Line one\nSay \"hi\"")
        #expect(toml.string("literal") == "C:\\path")
        #expect(toml.bool("compat.claude.skills") == false)
        #expect(toml.strings("paths.extra_rule_dirs") == ["~/rules", "/opt/r#x"])
        #expect(toml.sections.contains("compat.claude"))
    }

    @Test func tomlReadsMultilineArraysWithComments() {
        let toml = TOMLKeys("""
        [paths]
        extra_rule_dirs = [
          "~/a", # first
          '~/b',
        ]
        after = true
        """)
        #expect(toml.strings("paths.extra_rule_dirs") == ["~/a", "~/b"])
        #expect(toml.bool("paths.after") == true)
    }

    @Test func tomlSkipsMalformedLinesKeepsRest() {
        let toml = TOMLKeys("model = \"a\"\nbroken = [\"x\"\nok = true")
        #expect(toml.string("model") == "a")
        #expect(toml.bool("ok") == true)
    }

    @Test func jsoncKeepsCommentMarkersInsideStrings() {
        let object = JSONC.object("""
        {
          // comment
          "instructions": ["https://x.dev/a.md", "/* not a comment */"], /* block */
          "agent": { "a": { "prompt": "x // y", }, },
        }
        """)
        #expect(object?["instructions"] as? [String] == ["https://x.dev/a.md", "/* not a comment */"])
        #expect(((object?["agent"] as? [String: Any])?["a"] as? [String: Any])?["prompt"] as? String == "x // y")
    }

    @Test func tomlDecodesEscapesWithoutChangingLiterals() {
        let toml = TOMLKeys(#"""
        escaped = "Quote: \" Backslash: \\ Newline: \n Tab: \t Unicode: \u263A"
        literal = 'Keep \n \u263A # and "quotes"'
        """#)
        #expect(toml.string("escaped") == "Quote: \" Backslash: \\ Newline: \n Tab: \t Unicode: ☺")
        #expect(toml.string("literal") == #"Keep \n \u263A # and "quotes""#)
    }

    @Test func tomlPreservesMultilineWhitespaceAndCommentMarkers() {
        let toml = TOMLKeys(#"""
        text = """first

          # keep this
        last\nline""" # discard this
        after = true
        """#)
        #expect(toml.string("text") == "first\n\n  # keep this\nlast\nline")
        #expect(toml.bool("after") == true)
    }

    @Test func tomlReadsDottedKeysAndSectionComments() {
        let toml = TOMLKeys("""
        compat.claude.skills = false
        [compat.cursor] # keep section
        skills = false # disabled
        [skills] # empty section
        paths = []
        """)
        #expect(toml["compat.claude.skills"] == .bool(false))
        #expect(toml["compat.cursor.skills"] == .bool(false))
        #expect(toml["skills.paths"] == .strings([]))
        #expect(toml.sections == ["compat.cursor", "skills"])
        #expect(toml.string("compat.claude.skills") == nil)
        #expect(toml.bool("skills.paths") == nil)
        #expect(toml.strings("missing") == nil)
    }

    @Test func tomlRejectsMalformedValuesAndRecoversFollowingAssignments() {
        let toml = TOMLKeys(#"""
        invalid line
        bad_bool = falsehood
        bad_escape = "\q"
        bad_unicode = "\uD800"
        bad_string = "unterminated
        bad_array = ["a" "b"]
        bad_type = ["a", true]
        trailing = "a" garbage
        broken = """unterminated
        good = "kept"
        """#)
        for key in ["bad_bool", "bad_escape", "bad_unicode", "bad_string", "bad_array", "bad_type", "trailing", "broken"] {
            #expect(toml[key] == nil)
        }
        #expect(toml.string("good") == "kept")
    }

    @Test func tomlReadsWindowsNewlines() {
        let toml = TOMLKeys("text = \"\"\"\r\none\r\ntwo\"\"\"\r\n[paths]\r\nextra = [\r\n'a', # first\r\n'b',\r\n]\r\nafter = true")
        #expect(toml.string("text") == "one\ntwo")
        #expect(toml.strings("paths.extra") == ["a", "b"])
        #expect(toml.bool("paths.after") == true)
    }

    @Test(arguments: [#"\u+123"#, #"\u-000"#, #"\u12G4"#, #"\u123"#])
    func tomlRejectsMalformedUnicodeEscapes(escape: String) {
        let toml = TOMLKeys("bad = \"\(escape)\"\ngood = true")
        #expect(toml["bad"] == nil)
        #expect(toml.bool("good") == true)
    }

    @Test func jsoncPreservesEscapesAndCommaMarkersInsideStrings() {
        let object = JSONC.object(#"""
        {"escaped": "say \"hi\" // keep", "slash": "\\", "markers": ",] ,}", // discard
         "nested": [{"value": true, /* discard */ },],}
        """#)
        #expect(object?["escaped"] as? String == "say \"hi\" // keep")
        #expect(object?["slash"] as? String == "\\")
        #expect(object?["markers"] as? String == ",] ,}")
        #expect((object?["nested"] as? [[String: Bool]]) == [["value": true]])
    }

    @Test func jsoncDoesNotJoinTokensAcrossComments() {
        #expect(JSONC.object(#"{"number": 1/* gap */2}"#) == nil)
        #expect(JSONC.object(#"{"value": tr/* gap */ue}"#) == nil)
        #expect(JSONC.object("[]") == nil)
        #expect(JSONC.object("invalid") == nil)
        #expect(JSONC.strip(#"{"value": [1, 2,],}"#) == #"{"value": [1, 2]}"#)
    }

    @Test func grokCompatReadsCommentedSectionsAndTypedSwitches() {
        let compat = PluginReaders.grokCompat(config: """
        [compat.claude] # disable imported skills
        skills = false
        [compat.cursor]
        skills = false
        [skills] # tracked even when empty
        """)
        #expect(!compat.claudeSkills)
        #expect(!compat.cursorSkills)
        #expect(compat.hasSkillsSection)
        #expect(PluginReaders.grokCompat(config: nil) == .init())
        #expect(PluginReaders.grokCompat(config: "[compat.claude]\nskills = falsehood") == .init())
    }
}
