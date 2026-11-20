import ADPrivacy
import Testing

@Test("SEC-7 / §12.3: recursive exclusions include the directory and descendants but not sibling names")
func exclusionIncludesDirectoryAndDescendants() throws {
    let rules = try PathExclusions(["~/work/client-a/**"], hostHome: "/Users/synthetic")
    #expect(rules.matches("/Users/synthetic/work/client-a"))
    #expect(rules.matches("/Users/synthetic/work/client-a/"))
    #expect(rules.matches("/Users/synthetic/work/client-a/深层/repo"))
    #expect(!rules.matches("/Users/synthetic/work/client-ab"))
    #expect(!rules.matches("/home/synthetic/work/client-a/repo"))
}

@Test("SEC-7 / §12.3: single-component wildcards cannot cross directory separators")
func exclusionWildcardsStayWithinComponent() throws {
    let rules = try PathExclusions(["/work/客户-?/app-*", "/work/**/private/**/src"])
    #expect(rules.matches("/work/客户-甲/app-iOS"))
    #expect(!rules.matches("/work/客户-甲乙/app-iOS"))
    #expect(!rules.matches("/work/客户-甲/tmp/app-iOS"))
    #expect(!rules.matches("/Work/客户-甲/app-iOS"))
    #expect(rules.matches("/work/private/src"))
    #expect(rules.matches("/work/team/private/a/b/src"))
    #expect(!rules.matches("/work/a/public/src"))
    #expect(!rules.matches("/work/a/private/src/extra"))
}

@Test("SEC-7 / §12.3: comparison preserves Unicode spelling and treats the expanded home path literally")
func exclusionUsesExactSpelling() throws {
    let rules = try PathExclusions(["~/café/**", "/work/client[1]"], hostHome: "/Users/a?b*")
    #expect(rules.matches("/Users/a?b*/café/repo"))
    #expect(!rules.matches("/Users/axbzz/café/repo"))
    #expect(!rules.matches("/Users/a?b*/cafe\u{301}/repo"))
    #expect(rules.matches("/work/client[1]"))
    #expect(!rules.matches("/work/client1"))
}

@Test("SEC-7 / §12.3: invalid rules fail as a group without returning private paths")
func exclusionRejectsInvalidRules() throws {
    for bad in ["", "relative/path", "~other/private", "//host/private", "/ok//private", "/ok/../private", "/ok/./private", "/bad\u{0}path"] {
        #expect(throws: PathExclusions.Failure.invalidRule(index: 1)) {
            try PathExclusions(["/valid", bad])
        }
    }
    #expect(throws: PathExclusions.Failure.hostHomeRequired(index: 0)) {
        try PathExclusions(["~/private"])
    }
    #expect(throws: PathExclusions.Failure.invalidHostHome) {
        try PathExclusions(["~/private"], hostHome: "relative")
    }
    #expect(throws: PathExclusions.Failure.tooManyRules) {
        try PathExclusions(Array(repeating: "/private", count: 65))
    }
    #expect(throws: PathExclusions.Failure.invalidRule(index: 0)) {
        try PathExclusions(["/" + String(repeating: "a", count: 4096)])
    }
}

@Test("SEC-7 / §12.3: only valid absolute session paths participate")
func exclusionDoesNotNormalizeUntrustedPaths() throws {
    let all = try PathExclusions(["/**"])
    #expect(all.matches("/"))
    #expect(all.matches("/work/repo"))
    for bad in ["", "relative", "~/work/repo", "//work/repo", "/work//repo", "/work/../repo", "/work/./repo", "/bad\u{0}path"] {
        #expect(!all.matches(bad))
    }
    #expect(try !PathExclusions([]).matches("/work/repo"))
}
