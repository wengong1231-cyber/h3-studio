import Foundation

enum TaskVersionGroupingSelfTests {
    static func run(check: (String, Bool, String) throws -> Void) throws {
        var first = ShotJob.fixture(shot: 10, title: "S10 · 第1段")
        first.status = .completed; first.candidate = "/tmp/declared-old-candidate.mp4"
        var second = first; second.id = UUID(); second.title += " · 重做"
        second.redoOf = first.id; second.status = .failed; second.error = "fixture failure"
        second.candidate = nil; first.supersededBy = second.id
        var third = second; third.id = UUID(); third.title += " · 重做"
        third.redoOf = second.id; third.status = .blocked; third.error = nil
        second.supersededBy = third.id
        let input = [first, second, third], group = TaskVersionGrouping.project(input)[0]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(input)
        try check("多次重做只占一条任务",TaskVersionGrouping.project(input).count == 1 && group.versions.count == 3,"three recorded execution identities share one presentation")
        try check("归组当前版本准确",group.current.id == third.id && group.id == first.id,"root is stable row identity; latest is action target")
        try check("归组沿历史顺序编号",group.versions.map(\.id) == input.map(\.id) && group.versionNumber(second.id) == 2,"not creation-date or storage-order guessing")
        try check("归组显示原任务标题",group.title == first.title && group.current.title == third.title,"repeated redo suffixes are removed only from display")
        try check("历史候选仍可在输出页找到",group.matches("completed") && group.current.candidate == nil && group.versions[0].candidate == first.candidate,"preparing a redo does not hide the old video")
        try check("筛选仅按当前执行状态",group.matches("active") && !group.matches("errors"),"old failed version does not mark the new prepared version failed")
        try check("历史选择定位同一队列行",group.contains(first.id) && group.contains(second.id) && group.contains(third.id) && !group.contains(UUID()) && !group.contains(nil),"back/redo/history navigation keeps the same row highlighted")
        var next = third; next.id = UUID(); next.redoOf = third.id
        var replaced = third; replaced.supersededBy = next.id
        let updated = TaskVersionGrouping.project([first, second, replaced, next])[0]
        try check("新增重做不重建行身份",updated.id == group.id && updated.current.id == next.id,"stable SwiftUI ID across current-version changes")
        let shuffled = TaskVersionGrouping.project([third, first, second])[0]
        try check("归组不依赖记录排列",shuffled.versions.map(\.id) == input.map(\.id),"lineage remains correct after queue reorder")
        var unrelated = first; unrelated.id = UUID(); unrelated.supersededBy = nil
        let separate = TaskVersionGrouping.project([first, unrelated, second, third])
        try check("同镜号无关联保持独立",separate.count == 2 && separate.first?.current.id == unrelated.id,"no inferred merge of unrelated or imported candidates")
        try check("队列按当前版本真实位置排序",TaskVersionGrouping.project([third, unrelated, first, second]).map(\.current.id) == [third.id, unrelated.id],"moving current IDs updates the displayed order")
        func unmerged(_ jobs: [ShotJob]) -> Bool {
            let groups = TaskVersionGrouping.project(jobs)
            return groups.count == jobs.count && Set(groups.flatMap { $0.versions.map(\.id) }) == Set(jobs.map(\.id))
                && groups.allSatisfy { $0.relationshipIssue != nil }
        }
        try check("缺失后继保留可见记录",unmerged([first]),"no silent disappearance when target is missing")
        try check("缺失前驱保留可见记录",unmerged([third]),"no guessed root")
        var oneWay = first; oneWay.supersededBy = nil
        try check("单向关系不擅自合并",unmerged([oneWay, second, third]),"both recorded sides must agree")
        var branch = second; branch.id = UUID(); branch.supersededBy = nil
        try check("分叉关系全部保留可见",unmerged(input + [branch]),"ambiguous branch cannot disappear behind chosen leaf")
        var cycleFirst = first, cycleThird = third
        cycleFirst.redoOf = third.id; cycleThird.supersededBy = first.id
        try check("循环关系不死循环不隐藏",unmerged([cycleFirst, second, cycleThird]),"cycle fails closed to separate visible records")
        var cross = third; cross.shot = 11
        try check("跨镜冲突不合并",unmerged([first, second, cross]),"explicit links must also agree on shot and engine")
        var runningOld = first; runningOld.status = .running
        try check("运行旧版本始终可见",unmerged([runningOld, second, third]),"a process is never hidden as historical")
        var currentRunning = third; currentRunning.status = .running
        try check("当前运行版本保持单行",TaskVersionGrouping.project([first, second, currentRunning])[0].current.status == .running,"current execution and progress remain visible")
        var cancelled = third; cancelled.status = .cancelled
        try check("取消状态不会恢复为等待",!TaskVersionGrouping.project([first, second, cancelled])[0].matches("active"),"projection never revives cancelled tasks")
        try check("历史全部只读保留",try encoder.encode(input) == before && group.versions[1].error == second.error,"candidates, errors, IDs and source state remain byte equivalent")
        try check("空队列安全",TaskVersionGrouping.project([]).isEmpty,"no invented group")
    }
}
