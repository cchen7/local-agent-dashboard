import ADCore
import ADPrivacy
import ADStore
import Foundation

/// Presentation-only grouping of already ordered, already visible rows.
/// Identity comes exclusively from the Projects catalog, never displayed text.
public struct SessionProjectGrouping: Sendable {
    public struct Group: Identifiable, Equatable, Sendable {
        public enum ID: Hashable, Sendable { case project(IndexedProject.ID), ungrouped }

        public let id: ID
        public let name: String?
        public let context: String?
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public var id: Group.ID { group.id }
        public let group: Group
        public fileprivate(set) var sessions: [SessionKey]
    }

    private let membership: [SessionKey: Group]
    private static let ungrouped = Group(id: .ungrouped, name: nil, context: nil)

    public init(projects: [IndexedProject], maskSecrets: Bool = true) {
        func label(_ text: String?) -> String? {
            guard let text, !text.isEmpty, text.utf8.count <= 16_384 else { return nil }
            return maskSecrets ? IndexSecretMasker.text(text) : text
        }
        var memberships: [SessionKey: Group] = [:]
        for project in projects {
            let group = Group(id: .project(project.id), name: label(project.name),
                              context: label(project.location ?? project.path))
            for member in project.sessions {
                memberships[member.id] = group
            }
        }
        membership = memberships
    }

    /// The first visible row establishes its group's position. Preserve the
    /// original relative order of every row inside a group, including hits
    /// on a paged search result. Never add a row from outside this page.
    public func sections(for ordered: [SessionKey]) -> [Section] {
        var indices: [Group.ID: Int] = [:]
        var groups: [Section] = []
        for key in ordered {
            let group = membership[key] ?? Self.ungrouped
            if let index = indices[group.id] {
                groups[index].sessions.append(key)
            } else {
                indices[group.id] = groups.count
                groups.append(.init(group: group, sessions: [key]))
            }
        }
        return groups
    }
}
