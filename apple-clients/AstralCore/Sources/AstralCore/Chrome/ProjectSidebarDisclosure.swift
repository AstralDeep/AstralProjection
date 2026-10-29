// Keeps ephemeral project-tree disclosure choices independent of selection and execution authority.
// The Mac sidebar temporarily reveals search results without overwriting explicit user choices.

public struct ProjectSidebarDisclosure: Sendable {
    private var choices: [String: Bool] = [:]

    public init() {}

    public func isExpanded(_ project: String, selected: String?, active: String?, searching: Bool = false) -> Bool {
        searching || (choices[project] ?? (project == selected || project == active))
    }

    public mutating func toggle(_ project: String, selected: String?, active: String?, searching: Bool = false) {
        guard !searching else { return }
        choices[project] = !isExpanded(project, selected: selected, active: active)
    }

    public mutating func reveal(_ project: String) { choices[project] = true }

    public mutating func retain(_ projects: Set<String>) {
        choices = choices.filter { projects.contains($0.key) }
    }
}
