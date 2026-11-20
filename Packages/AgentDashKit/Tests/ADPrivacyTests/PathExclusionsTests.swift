import ADPrivacy
import Testing

@Test("SEC-7 / §12.3: recursive exclusions include the directory and descendants but not sibling names")
func exclusionIncludesDirectoryAndDescendants() throws {
    let rules = try PathExclusions(["~/work/client-a/**"], hostHome: "/Users/synthetic")
    #expect(rules.decision(for: "/Users/synthetic/work/client-a") == .excluded)
    #expect(rules.decision(for: "/Users/synthetic/work/client-a/") == .excluded)
    #expect(rules.decision(for: "/Users/synthetic/work/client-a/深层/repo") == .excluded)
    #expect(rules.decision(for: "/Users/synthetic/work/client-ab") == .notExcluded)
    #expect(rules.decision(for: "/home/synthetic/work/client-a/repo") == .notExcluded)
}

@Test("SEC-7 / §12.3: single-component wildcards cannot cross directory separators")
func exclusionWildcardsStayWithinComponent() throws {
    let rules = try PathExclusions(["/work/客户-?/app-*", "/work/**/private/**/src"])
    #expect(rules.decision(for: "/work/客户-甲/app-iOS") == .excluded)
    #expect(rules.decision(for: "/work/客户-甲乙/app-iOS") == .notExcluded)
    #expect(rules.decision(for: "/work/客户-甲/tmp/app-iOS") == .notExcluded)
    #expect(rules.decision(for: "/Work/客户-甲/app-iOS") == .notExcluded)
    #expect(rules.decision(for: "/work/private/src") == .excluded)
    #expect(rules.decision(for: "/work/team/private/a/b/src") == .excluded)
    #expect(rules.decision(for: "/work/a/public/src") == .notExcluded)
    #expect(rules.decision(for: "/work/a/private/src/extra") == .notExcluded)
}

@Test("SEC-7 / §12.3: alternate POSIX spellings cannot bypass a directory exclusion")
func exclusionMatchesEquivalentSpellings() throws {
    let rules = try PathExclusions(["/work/client-a/**"])
    #expect(rules.decision(for: "/work//client-a/./repo") == .excluded)
    #expect(rules.decision(for: "/work/./client-a//repo/") == .excluded)
    #expect(rules.decision(for: "/work//client-ab/./repo") == .notExcluded)
}

@Test("SEC-7 / §12.3: comparison preserves Unicode spelling and treats the expanded home path literally")
func exclusionUsesExactSpelling() throws {
    let rules = try PathExclusions(["~/café/**", "/work/client[1]"], hostHome: "/Users/a?b*")
    #expect(rules.decision(for: "/Users/a?b*/café/repo") == .excluded)
    #expect(rules.decision(for: "/Users/axbzz/café/repo") == .notExcluded)
    #expect(rules.decision(for: "/Users/a?b*/cafe\u{301}/repo") == .notExcluded)
    #expect(rules.decision(for: "/work/client[1]") == .excluded)
    #expect(rules.decision(for: "/work/client1") == .notExcluded)
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

@Test("SEC-7 / §12.3: ambiguous paths are distinct from definite non-matches")
func exclusionDistinguishesIndeterminatePaths() throws {
    let rules = try PathExclusions(["/work/client-a/**"])
    #expect(rules.decision(for: "/work/client-ab") == .notExcluded)
    #expect(rules.decision(for: "//work/client-a") == .indeterminate)
    #expect(rules.decision(for: "///work/client-a") == .excluded)
    for path in ["", "relative", "~/work/repo", "/work/link/../client-a", "/work/client-a/../other", "/bad\u{0}path"] {
        #expect(rules.decision(for: path) == .indeterminate)
    }

    let all = try PathExclusions(["/**"])
    #expect(all.decision(for: "/") == .excluded)
    #expect(all.decision(for: "/./") == .excluded)
    #expect(all.decision(for: "/work/link/../client-a") == .indeterminate)
    #expect(try PathExclusions([]).decision(for: "relative") == .notExcluded)
}
