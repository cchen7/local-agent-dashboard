import ADPrivacy
import Testing

private let marker = "••••••"

@Test("SEC-8 / §12.2: credential-shaped tokens are masked without changing surrounding Unicode")
func masksKnownCredentialShapes() {
    let tokens = [
        "sk-proj-" + String(repeating: "demo_", count: 6),
        "ghp_" + String(repeating: "example1", count: 5),
        "github_pat_" + String(repeating: "sample_", count: 5),
        "AKIA" + String(repeating: "DEMO", count: 4),
        "xoxb-" + String(repeating: "12345-", count: 3) + "demo",
        "xoxp-" + String(repeating: "demo1234", count: 3),
    ]
    let text = "配置🔐：" + tokens.joined(separator: "；") + "完成\n"
    #expect(SecretMasker.mask(text) == "配置🔐：" + Array(repeating: marker, count: tokens.count)
        .joined(separator: "；") + "完成\n")
}

@Test("SEC-8 / §12.2: short placeholders and token-like identifier suffixes remain visible")
func keepsUnrelatedText() {
    let lookalike = "prefix_ghp_" + String(repeating: "demo", count: 9)
    let text = "Use sk-… or xoxb-demo.\n\(lookalike)\nPUBLIC_ENDPOINT=https://example.invalid\n"
    #expect(SecretMasker.mask(text) == text)
}

@Test("SEC-8 / §12.2: dotenv masking keeps variable names, quoting, comments and line endings")
func masksAssignmentValues() {
    let text = "export service_token = \"演示\\\"字串\" # example\r\n"
        + "API_KEY = word#continuation  # keep comment\r\n"
        + "BUILD_SECRET='测试😺'\r\n"
        + "APP_PASSWORD = demo with spaces\r\n"
        + "EMPTY_TOKEN=   # unset\r\n"
        + "MODE=development\r\n"
    let expected = "export service_token = \"\(marker)\" # example\r\n"
        + "API_KEY = \(marker)  # keep comment\r\n"
        + "BUILD_SECRET='\(marker)'\r\n"
        + "APP_PASSWORD = \(marker)\r\n"
        + "EMPTY_TOKEN=   # unset\r\n"
        + "MODE=development\r\n"
    #expect(SecretMasker.mask(text) == expected)
    #expect(SecretMasker.mask(expected) == expected)
}

@Test("SEC-8 / §12.2: multiline and truncated sensitive assignments do not expose partial values")
func masksMultilineValues() {
    let text = "API_SECRET=\"first synthetic line\nsecond synthetic line\"\nMODE=demo\n"
    #expect(SecretMasker.mask(text) == "API_SECRET=\"\(marker)\"\nMODE=demo\n")
    let truncated = "DEBUG=yes\nAPI_SECRET=\"first synthetic line\npartial second line"
    #expect(SecretMasker.mask(truncated) == "DEBUG=yes\nAPI_SECRET=\"\(marker)")
}

@Test("SEC-8 / §12.2: private key blocks require a matching end and are masked if truncated")
func masksPrivateKeyBlocks() {
    let text = "说明\n-----BEGIN OPENSSH PRIVATE KEY-----\nSYNTHETIC BODY\n"
        + "-----END RSA PRIVATE KEY-----\nSTILL PRIVATE\n"
        + "-----END OPENSSH PRIVATE KEY-----\n不会吞掉下一行\n"
    #expect(SecretMasker.mask(text) == "说明\n\(marker)\n不会吞掉下一行\n")
    let truncated = "note\n-----BEGIN PRIVATE KEY-----\nSYNTHETIC TRUNCATED BODY"
    #expect(SecretMasker.mask(truncated) == "note\n\(marker)")
    let certificate = "-----BEGIN CERTIFICATE-----\nPUBLIC DEMO\n-----END CERTIFICATE-----"
    #expect(SecretMasker.mask(certificate) == certificate)
}

@Test("SEC-8 / §12.2: overlapping token and assignment matches produce one replacement")
func coalescesOverlappingRedactions() {
    let token = "sk-" + String(repeating: "demo", count: 7)
    #expect(SecretMasker.mask("AUTH_TOKEN=\(token) # demo\n") == "AUTH_TOKEN=\(marker) # demo\n")
}
