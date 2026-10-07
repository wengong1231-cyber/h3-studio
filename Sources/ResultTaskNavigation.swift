import Foundation

/// UI navigation evidence only. These links cannot authorize generation or QA.
struct ResultRevisionLink: Codable, Equatable {
    var fromRevision: Int
    var toRevision: Int
    var previousStateSHA256: String
    var promptSHA256: String
}
struct ResultRouteOrigin: Equatable {
    var jobID: UUID
    var revision: Int
    var frozenStateSHA256: String?
    static func current(_ job: ShotJob) -> Self { .init(jobID:job.id,revision:job.actionRevisionNumber,frozenStateSHA256:nil) }
}
struct ResultTaskTarget: Identifiable, Equatable {
    var jobID: UUID
    var revision: Int
    var title: String
    var status: String
    var id: UUID { jobID }
    var label: String { title + " · r\(revision) · " + String(jobID.uuidString.prefix(6)) + " · " + status }
}
struct RedoRouteResolution {
    var target: ResultTaskTarget?
    var history: [ResultTaskTarget]
    var unavailableReason: String?
}

extension ShotJob {
    var actionRevisionNumber: Int { h3FirstProposal?.queueExecution?.actionRevision?.number ?? 1 }
    var effectiveResultRevisionLinks: [ResultRevisionLink] {
        var links = resultRevisionLinks ?? []
        if let revision = h3FirstProposal?.queueExecution?.actionRevision,revision.number >= 2,
           !links.contains(where:{ $0.toRevision == revision.number && $0.previousStateSHA256 == revision.previousStateSHA256 }) {
            links.append(.init(fromRevision:revision.number-1,toRevision:revision.number,
                previousStateSHA256:revision.previousStateSHA256,promptSHA256:revision.promptSHA256))
        }
        return links
    }
    var resultTaskTarget: ResultTaskTarget { .init(jobID:id,revision:actionRevisionNumber,title:focusTaskLabel,status:displayStatusLabel) }
}

enum RedoRouteResolver {
    static func resolve(_ origin: ResultRouteOrigin,jobs: [ShotJob]) -> RedoRouteResolution {
        guard let source = jobs.first(where:{ $0.id == origin.jobID }) else {
            return .init(target:nil,history:[],unavailableReason:"原任务已删除或未导入，无法核对重做关系")
        }
        var current = source,seen: Set<UUID> = [source.id],history: [ResultTaskTarget] = []
        if origin.revision < source.actionRevisionNumber {
            let links = source.effectiveResultRevisionLinks.sorted { $0.fromRevision < $1.fromRevision }
            var number = origin.revision
            guard number >= 1,let hash = origin.frozenStateSHA256,
                  links.contains(where:{ $0.fromRevision == number && $0.previousStateSHA256 == hash }) else {
                return .init(target:nil,history:[],unavailableReason:"旧结果缺少同一任务修订的冻结关系，不能按版本号猜测")
            }
            for link in links where link.fromRevision == number {
                guard link.toRevision == number+1,ModelStatusReader.isHash(link.previousStateSHA256,length:64),
                      ModelStatusReader.isHash(link.promptSHA256,length:64) else { break }
                number = link.toRevision
            }
            guard number == source.actionRevisionNumber else {
                return .init(target:nil,history:[],unavailableReason:"修订历史链不完整，无法定位最新修订")
            }
            history.append(source.resultTaskTarget)
        }
        for _ in 0..<2000 {
            let children = jobs.filter { $0.redoOf == current.id }
            let nextID: UUID?
            if let explicit = current.supersededBy { nextID = explicit }
            else if children.count == 1 { nextID = children[0].id }
            else if children.count > 1 { return .init(target:nil,history:history,unavailableReason:"重做关系存在多个分支，无法确定最新任务") }
            else { nextID = nil }
            guard let nextID else { break }
            guard let successor = jobs.first(where:{ $0.id == nextID }),
                  successor.redoOf == nil || successor.redoOf == current.id else {
                return .init(target:nil,history:history,unavailableReason:"重做目标缺失或关系冲突，原结果仍保留")
            }
            guard seen.insert(nextID).inserted else {
                return .init(target:nil,history:history,unavailableReason:"重做关系形成循环，无法导航")
            }
            current = successor;history.append(current.resultTaskTarget)
        }
        guard let target = history.last else {
            return .init(target:nil,history:[],unavailableReason:source.externalHistory != nil ? "此历史结果未保存 App 重做关系" : "尚未创建关联的重做任务")
        }
        return .init(target:target,history:history,unavailableReason:nil)
    }
}

struct TaskNavigationLocation: Equatable {
    var selectedID: UUID?
    var filter = "all"
    var inspectorTab = 0
    var metrics = false
    var models = false
}
struct TaskNavigationIntent: Identifiable {
    var id = UUID()
    var destination: TaskNavigationLocation
}

extension TaskStore {
    func redoRoute(for origin: ResultRouteOrigin) -> RedoRouteResolution { RedoRouteResolver.resolve(origin,jobs:state.jobs) }
    /// Only selection and transient UI navigation change. No persist, import,
    /// redo, queue start, receipt write, subprocess or generation side effect.
    @discardableResult func navigateToRedo(_ origin: ResultRouteOrigin,from location: TaskNavigationLocation,historyTarget: UUID? = nil) -> Bool {
        let route = redoRoute(for:origin)
        guard let latest = route.target,let target = historyTarget.flatMap({ id in route.history.first { $0.jobID == id } }) ?? (historyTarget == nil ? latest : nil),
              let job = state.jobs.first(where:{ $0.id == target.jobID }),job.actionRevisionNumber == target.revision else {
            notice = route.unavailableReason ?? "重做目标已改变，请重新打开结果";return false
        }
        navigationBackStack.append(location)
        selectedID = target.jobID
        navigationIntent = .init(destination:.init(selectedID:target.jobID))
        return true
    }
    @discardableResult func navigateToTask(_ id: UUID,from location: TaskNavigationLocation) -> Bool {
        guard state.jobs.contains(where:{ $0.id == id }) else { return false }
        navigationBackStack.append(location);selectedID = id
        navigationIntent = .init(destination:.init(selectedID:id));return true
    }
    @discardableResult func returnFromTaskNavigation() -> Bool {
        guard let previous = navigationBackStack.popLast() else { return false }
        var destination = previous
        if !state.jobs.contains(where:{ $0.id == previous.selectedID }) { destination.selectedID = nil }
        selectedID = destination.selectedID;navigationIntent = .init(destination:destination);return true
    }
}
