import Foundation
import Testing
import ADCore

@Suite("FR-SRC-1 / SEC-3: pure display and future copy-resume path mapping")
struct PathMapperTests {
    @Test("The longest component prefix wins independently of rule order")
    func longestPrefix() throws {
        let root = PathMapping(from: "/", to: "/fallback")
        let workspace = PathMapping(from: "/workspace", to: "/host/code")
        let project = PathMapping(from: "/workspace/api", to: "/host/special")
        for rules in [
            [root, workspace, project], [root, project, workspace],
            [workspace, root, project], [workspace, project, root],
            [project, root, workspace], [project, workspace, root]
        ] {
            #expect(try PathMapper.map("/workspace/api/Sources/main.swift", using: rules) == "/host/special/Sources/main.swift")
            #expect(try PathMapper.map("/workspace/api", using: rules) == "/host/special")
            #expect(try PathMapper.map("/workspace/web", using: rules) == "/host/code/web")
            #expect(try PathMapper.map("/elsewhere", using: rules) == "/fallback/elsewhere")
        }
    }

    @Test("A textual prefix cannot consume part of a component", arguments: [
        ("/workspace-two/api", "/workspace-two/api"),
        ("/workspaces/api", "/workspaces/api"),
        ("/workspace/api-v2/file", "/host/api-v2/file"),
        ("/workspace/api/file", "/special/file")
    ])
    func componentBoundaries(_ input: String, _ expected: String) throws {
        let rules = [PathMapping(from: "/workspace", to: "/host"),
                     PathMapping(from: "/workspace/api", to: "/special")]
        #expect(try PathMapper.map(input, using: rules) == expected)
    }

    @Test("Matching is case-sensitive and preserves destination and suffix case")
    func caseSensitivity() throws {
        let rules = [PathMapping(from: "/Workspace", to: "/Host/Upper"),
                     PathMapping(from: "/workspace", to: "/Host/Lower")]
        #expect(try PathMapper.map("/Workspace/API", using: rules) == "/Host/Upper/API")
        #expect(try PathMapper.map("/workspace/Api", using: rules) == "/Host/Lower/Api")
        #expect(try PathMapper.map("/WORKSPACE/API", using: rules) == "/WORKSPACE/API")
    }

    @Test("Rule trailing separators are ignored; mapped input retains one trailing separator", arguments: [
        ("/workspace", "/workspace/", "/host/", "/host"),
        ("/workspace/", "/workspace", "/host", "/host/"),
        ("/workspace///", "/workspace///", "/host///", "/host/"),
        ("/workspace/api/", "/workspace/", "/host/", "/host/api/"),
        ("/workspace/api///", "/workspace///", "/host///", "/host/api/")
    ])
    func trailingSeparators(_ input: String, _ from: String, _ to: String, _ expected: String) throws {
        #expect(try PathMapper.map(input, using: [.init(from: from, to: to)]) == expected)
    }

    @Test("Root sources and destinations join without losing or doubling separators", arguments: [
        ("/", "/", "/host/", "/host"),
        ("/api", "/", "/host", "/host/api"),
        ("/api/", "/", "/host", "/host/api/"),
        ("/", "/", "/", "/"),
        ("/api", "/", "/", "/api"),
        ("/workspace", "/workspace", "/", "/"),
        ("/workspace/", "/workspace", "/", "/"),
        ("/workspace/api/", "/workspace/", "/", "/api/")
    ])
    func roots(_ input: String, _ from: String, _ to: String, _ expected: String) throws {
        #expect(try PathMapper.map(input, using: [.init(from: from, to: to)]) == expected)
    }

    @Test("Unmatched paths are returned byte-for-byte, including repeated trailing separators")
    func unmatched() throws {
        for input in ["/", "/elsewhere///", "/Workspace/项目/", "/other/$HOME/~user/*"] {
            let actual = try PathMapper.map(input, using: [.init(from: "/workspace", to: "/host")])
            #expect(actual.utf8.elementsEqual(input.utf8))
            #expect(try PathMapper.map(input, using: []).utf8.elementsEqual(input.utf8))
        }
    }

    @Test("Only an explicit host home expands a destination ~/ prefix", arguments: [
        ("~/code/", "/host/home/", "/host/home/code/api"),
        ("~/", "/host/home", "/host/home/api"),
        ("~/code", "/", "/code/api"),
        ("~/", "/", "/api")
    ])
    func explicitHome(_ destination: String, _ home: String, _ expected: String) throws {
        #expect(try PathMapper.map("/workspace/api", using: [.init(from: "/workspace", to: destination)],
                                   hostHome: home) == expected)
    }

    @Test("A home-dependent rule without host home fails even when unmatched")
    func missingHome() {
        for input in ["/workspace/api", "/other"] {
            #expect(throws: PathMapper.Failure.hostHomeRequired(ruleIndex: 0)) {
                try PathMapper.map(input, using: [.init(from: "/workspace", to: "~/code")])
            }
        }
    }

    @Test("Explicit host home must itself be an unambiguous absolute path", arguments: [
        "", "relative", "~/home", "//host/home", "/host//home", "/host/./home", "/host/../home", "/host\0home"
    ])
    func invalidHome(_ home: String) {
        #expect(throws: PathMapper.Failure.invalidHostHome) {
            try PathMapper.map("/workspace", using: [.init(from: "/workspace", to: "~/code")], hostHome: home)
        }
    }

    @Test("An unused host-home value has no effect on absolute destinations")
    func unusedHome() throws {
        #expect(try PathMapper.map("/workspace/api", using: [.init(from: "/workspace", to: "/host")],
                                   hostHome: "not-an-absolute-home") == "/host/api")
    }

    @Test("Invalid sources are distinguished by rule index", arguments: [
        "", "workspace", "~/workspace", "//workspace", "///", "/work//space", "/work/./space",
        "/work/../space", "/.", "/..", "/work\0space", "file:///workspace", "C:\\workspace"
    ])
    func invalidSources(_ from: String) {
        #expect(throws: PathMapper.Failure.invalidFrom(ruleIndex: 1)) {
            try PathMapper.map("/elsewhere", using: [.init(from: "/valid", to: "/host"), .init(from: from, to: "/host")])
        }
    }

    @Test("Invalid destinations are never shell-expanded or standardized", arguments: [
        "", "host/code", "~", "~someone/code", "$HOME/code", "file:///host", "//host", "/host//code",
        "/host/./code", "/host/../code", "/host\0code", "~/../code", "~//code"
    ])
    func invalidDestinations(_ to: String) {
        #expect(throws: PathMapper.Failure.invalidTo(ruleIndex: 0)) {
            try PathMapper.map("/workspace", using: [.init(from: "/workspace", to: to)], hostHome: "/host/home")
        }
    }

    @Test("Unsupported input is distinct from a valid unmatched path", arguments: [
        "", "relative/path", "~/workspace", "//workspace", "///", "/work//space", "/workspace/./api",
        "/workspace/../api", "/.", "/..", "/workspace/api\0suffix"
    ])
    func invalidInputs(_ input: String) {
        #expect(throws: PathMapper.Failure.invalidPath) {
            try PathMapper.map(input, using: [.init(from: "/", to: "/host")])
        }
    }

    @Test("Invalid rules cannot silently fall back to a shorter prefix")
    func noInvalidFallback() {
        #expect(throws: PathMapper.Failure.invalidTo(ruleIndex: 1)) {
            try PathMapper.map("/workspace/api/file", using: [
                .init(from: "/workspace", to: "/host"), .init(from: "/workspace/api", to: "relative")
            ])
        }
    }

    @Test("Conflicting normalized sources fail rather than choosing an array order", arguments: [
        ("/workspace", "/workspace/"), ("/workspace///", "/workspace"), ("/", "/")
    ])
    func ambiguousRules(_ first: String, _ second: String) {
        let rules = [PathMapping(from: first, to: "/host/one"), PathMapping(from: second, to: "/host/two")]
        for orderedRules in [rules, Array(rules.reversed())] {
            for input in ["/workspace/api", "/elsewhere"] {
                #expect(throws: PathMapper.Failure.ambiguousRules(firstIndex: 0, secondIndex: 1)) {
                    try PathMapper.map(input, using: orderedRules)
                }
            }
        }
    }

    @Test("Equivalent duplicate destinations are harmless, including an explicit home expansion")
    func equivalentDuplicates() throws {
        #expect(try PathMapper.map("/workspace/api", using: [
            .init(from: "/workspace", to: "/host/home/code/"),
            .init(from: "/workspace///", to: "~/code")
        ], hostHome: "/host/home/") == "/host/home/code/api")
        #expect(throws: PathMapper.Failure.ambiguousRules(firstIndex: 0, secondIndex: 1)) {
            try PathMapper.map("/workspace/api", using: [
                .init(from: "/workspace", to: "/host/Code"), .init(from: "/workspace", to: "/host/code")
            ])
        }
    }

    @Test("Unicode, whitespace and shell metacharacters stay literal; mapping happens once")
    func literalPaths() throws {
        let suffix = "/项目/$HOME/$(ignored)/*/~user/a b\\c/\"quoted\""
        let rules = [PathMapping(from: "/workspace", to: "/host/$HOME"),
                     PathMapping(from: "/host", to: "/must-not-chain")]
        #expect(try PathMapper.map("/workspace" + suffix, using: rules) == "/host/$HOME" + suffix)
        #expect(try PathMapper.map("/workspace/\u{301}name/file", using: [
            .init(from: "/workspace", to: "/host"), .init(from: "/workspace/\u{301}name", to: "/special")
        ]) == "/special/file")
    }

    @Test("Unicode spellings are compared as bytes without canonical normalization")
    func unicodeSpellings() throws {
        let composed = "/caf\u{e9}"
        let decomposed = "/cafe\u{301}"
        let input = decomposed + "/file"
        let unmatched = try PathMapper.map(input, using: [.init(from: composed, to: "/host")])
        #expect(unmatched.utf8.elementsEqual(input.utf8))
        #expect(try PathMapper.map(input, using: [
            .init(from: composed, to: "/one"), .init(from: decomposed, to: "/two")
        ]) == "/two/file")
        #expect(throws: PathMapper.Failure.ambiguousRules(firstIndex: 0, secondIndex: 1)) {
            try PathMapper.map("/workspace", using: [
                .init(from: "/workspace", to: composed), .init(from: "/workspace", to: decomposed)
            ])
        }
    }

    @Test("PathMapping retains exactly its existing from/to Codable shape and unmodified values")
    func codableCompatibility() throws {
        let json = Data(#"[{"from":"/workspace/","to":"~/code/"}]"#.utf8)
        let rules = try JSONDecoder().decode([PathMapping].self, from: json)
        #expect(try PathMapper.map("/workspace/api", using: rules, hostHome: "/host/home") == "/host/home/code/api")
        #expect(rules == [.init(from: "/workspace/", to: "~/code/")])
        let encoded = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode([[String: String]].self, from: encoded) == [
            ["from": "/workspace/", "to": "~/code/"]
        ])
    }
}
