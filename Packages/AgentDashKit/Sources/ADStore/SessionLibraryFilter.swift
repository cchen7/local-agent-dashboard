import ADCore

/// A sidebar selection is separate from search text. Environment identity
/// uses exact recorded bytes; its display label may be masked.
public enum SessionLibraryFilter: Equatable, Sendable {
    case agent(AgentKind)
    case environment(String)
    case status(SessionStatus)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.agent(a), .agent(b)): a == b
        case let (.environment(a), .environment(b)): a.utf8.elementsEqual(b.utf8)
        case let (.status(a), .status(b)): a == b
        default: false
        }
    }

    public func includes(agent: AgentKind, environment: String, status: SessionStatus) -> Bool {
        switch self {
        case .agent(let value): value == agent
        case .environment(let value): value.utf8.elementsEqual(environment.utf8)
        case .status(let value): value == status
        }
    }
}
