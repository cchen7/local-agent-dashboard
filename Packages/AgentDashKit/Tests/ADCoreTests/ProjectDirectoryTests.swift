import ADCore
import Foundation
import Testing

@Test("SEC-3 / §11.3: Finder receives a pinned local project directory but not aliases through symlinks")
func verifiedLocalProjectDirectoryRejectsSymlinkComponents() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("project-directory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("project")
    let child = project.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let leaf = base.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: project)
    let file = project.appendingPathComponent("regular-file")
    try Data([0x41]).write(to: file)

    let received = try ProjectDirectory.withVerifiedLocalDirectory(child.path) { $0 }
    #expect(received.isFileURL && received.lastPathComponent == "nested")
    #expect(throws: (any Error).self) { try ProjectDirectory.withVerifiedLocalDirectory(leaf.path) { _ in } }
    #expect(throws: (any Error).self) {
        try ProjectDirectory.withVerifiedLocalDirectory(leaf.appendingPathComponent("nested").path) { _ in }
    }
    #expect(throws: (any Error).self) { try ProjectDirectory.withVerifiedLocalDirectory(file.path) { _ in } }
    #expect(throws: (any Error).self) { try ProjectDirectory.withVerifiedLocalDirectory("relative/project") { _ in } }
    #expect(throws: (any Error).self) { try ProjectDirectory.withVerifiedLocalDirectory(child.path + "/../nested") { _ in } }
}
