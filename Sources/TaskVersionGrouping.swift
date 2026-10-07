import Foundation

/// A read-only presentation of one task's recorded redo lineage. Execution,
/// acceptance and input identities always remain on the original ShotJob IDs.
struct TaskVersionGroup: Identifiable {
    let id: UUID
    let versions: [ShotJob] // oldest to current
    let relationshipIssue: String?
    var current: ShotJob { versions[versions.count - 1] }
    var title: String { versions[0].title }
    var hasHistory: Bool { versions.count > 1 }
    func contains(_ id: UUID?) -> Bool { versions.contains { $0.id == id } }
    func versionNumber(_ id: UUID) -> Int { (versions.firstIndex { $0.id == id } ?? 0) + 1 }
    func matches(_ filter: String) -> Bool {
        switch filter {
        case "active": return current.status.isPending || current.status.isActive
        // Old candidates stay discoverable while the current version is being prepared.
        case "completed": return versions.contains { $0.candidate != nil || $0.status == .completed }
        case "errors": return [.failed, .interrupted].contains(current.status) || current.h3VideoRejection != nil
        default: return true
        }
    }
}

enum TaskVersionGrouping {
    static func project(_ jobs: [ShotJob]) -> [TaskVersionGroup] {
        let byID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        let positions = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($0.element.id, $0.offset) })
        var neighbours: [UUID: Set<UUID>] = [:]
        for job in jobs {
            for other in [job.redoOf, job.supersededBy].compactMap({ $0 }) where byID[other] != nil {
                neighbours[job.id, default: []].insert(other)
                neighbours[other, default: []].insert(job.id)
            }
        }
        var seen = Set<UUID>(), groups: [TaskVersionGroup] = []
        for job in jobs where !seen.contains(job.id) {
            var pending = [job.id], members = Set<UUID>()
            while let id = pending.popLast() {
                guard members.insert(id).inserted else { continue }
                pending.append(contentsOf: neighbours[id] ?? [])
            }
            seen.formUnion(members)
            let component = jobs.filter { members.contains($0.id) }
            if let chain = validatedChain(component, byID: byID) {
                groups.append(.init(id: chain[0].id, versions: chain, relationshipIssue: nil))
            } else {
                // Missing, branching, cyclic or incompatible relationships must
                // never conceal a record or an active process behind another row.
                groups.append(contentsOf: component.map {
                    .init(id: $0.id, versions: [$0], relationshipIssue: "重做关系不完整或有冲突，暂单独显示；原记录已保留。")
                })
            }
        }
        // Follow the actual current records' queue order, including drag/reorder.
        // The root ID remains stable when a new version becomes current.
        return groups.sorted { positions[$0.current.id]! < positions[$1.current.id]! }
    }

    private static func validatedChain(_ jobs: [ShotJob], byID: [UUID: ShotJob]) -> [ShotJob]? {
        for job in jobs {
            if let parentID = job.redoOf {
                guard let parent = byID[parentID], parent.supersededBy == job.id,
                      compatible(parent, job) else { return nil }
            }
            if let childID = job.supersededBy {
                guard let child = byID[childID], child.redoOf == job.id,
                      compatible(job, child), !job.status.isActive,
                      job.externalHistory?.observing != true else { return nil }
            }
        }
        let roots = jobs.filter { $0.redoOf == nil }
        guard roots.count == 1 else { return nil }
        var chain: [ShotJob] = [], visited = Set<UUID>(), cursor: ShotJob? = roots[0]
        while let current = cursor {
            guard visited.insert(current.id).inserted else { return nil }
            chain.append(current)
            cursor = current.supersededBy.flatMap { byID[$0] }
        }
        return chain.count == jobs.count ? chain : nil
    }

    private static func compatible(_ a: ShotJob, _ b: ShotJob) -> Bool {
        guard a.shot == b.shot, a.engine == b.engine else { return false }
        switch (a.h3QueuePlan, b.h3QueuePlan) {
        case let (a?, b?): return a.requestID == b.requestID && a.part == b.part
        case (nil, nil): return true
        default: return false
        }
    }
}
