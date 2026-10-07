import Foundation

struct H3QueuePlan: Codable, Equatable {
    var requestID: String
    var manifestSHA256: String
    var manifestSnapshotPath: String?
    var shot: Int
    var part: Int
    var partCount: Int
    var priority: Int
    var actionGoal: String
    var identityReferencePath: String
    var identityReferenceSHA256: String
    var identityReferenceMatches: Bool
    var sourceMediaPath: String?
    var sourceMediaSHA256: String?
    var sourceGlobalFrameIndex: Int?
    var dependencyRequestID: String?
    var dependencyRawIndex: Int?
    var promptPath: String
    var promptSHA256: String
    var profile: H3Profile
    var seed: Int
    var selectedRawStart: Int
    var selectedRawEnd: Int
    var destinationStart: Int
    var destinationEnd: Int
    var detailedFirstContractPath: String?
    var statusLabel: String { dependencyRequestID == nil ? "待准备" : "等待前段" }
    var blocker: String {
        if let dependencyRequestID,let dependencyRawIndex { return "等待 \(dependencyRequestID) 的 raw\(dependencyRawIndex) 端点及画面检查。" }
        return "实际首帧与完整画面预览尚未准备，生成输入检查未完成。"
    }
    static var knownPath: URL {
        AppIdentity.modelStatusRoot.appendingPathComponent("proposals/H3-App-remaining-queue-20261006/App-queue-manifest.local.json")
    }
}

struct H3QueueRead {
    var data: Data
    var hash: String
    var jobs: [ShotJob]
}

enum H3QueueReader {
    static func load(_ url: URL,runtime: H3Runtime) throws -> H3QueueRead {
        _ = try H3Files.inside(url.path,runtime.workDirectory + "/proposals")
        return try parse(H3Files.read(url,limit:2_097_152),runtime:runtime)
    }
    static func parse(_ data: Data,runtime: H3Runtime) throws -> H3QueueRead {
        guard data.count <= 2_097_152 else { throw StudioError.invalid("清单超过读取上限。") }
        let hash = H3ABConfigurationReader.digest(data)
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              root["schema"] as? String == "H3-App-remaining-image-action-queue-preparation-v1",
              root["generation_parallelism"] as? Int == 1,
              let authority = root["authorization"] as? [String:Any],
              authority["generation_and_App_queue_authorized"] as? Bool == true,
              authority["all_future_video_operations_in_App_required"] as? Bool == true,
              let order = root["order"] as? [Int],order.count == 17,Set(order).count == 17,
              !order.contains(where:{ [15,40,41].contains($0) }),
              let rows = root["items"] as? [[String:Any]],rows.count == order.count,
              let summary = root["summary"] as? [String:Any],summary["proposed_short_native_parts"] as? Int == 33,
              let master = root["effective_current_master"] as? [String:Any],
              let masterPath = master["path"] as? String,let masterHash = master["sha256"] as? String,
              let masterFrames = master["video_frames"] as? Int,masterFrames > 0,master["fps"] as? Int == 24,
              root["model_ref"] as? String == "local/MiniMax-H3-FL2VA-8bit",
              root["lora_ref"] as? String == "larryvrh/MiniMax-H3-Turbo-Lora-v4-600-ema",
              root["model_workspace_path"] as? String == runtime.workDirectory else {
            throw StudioError.invalid("需要已核 17 镜、33 短段串行准备清单；清单不是可执行队列。")
        }
        _ = try H3Files.inside(masterPath,runtime.workDirectory)
        guard ModelStatusReader.isHash(masterHash,length:64),
              runtime.mode == .mock || (root["helper_sha256"] as? String == H3ABConfigurationReader.helperSHA256
                && root["library_sha256"] as? String == H3ABConfigurationReader.librarySHA256) else { throw StudioError.invalid("清单母片或原生引擎指纹无效。") }
        var jobs: [ShotJob] = [],requests = Set<String>()
        for (rowIndex,row) in rows.enumerated() {
            guard let shot = row["shot"] as? Int,shot == order[rowIndex],(1...99).contains(shot),
                  row["user_authorized_generation"] as? Bool == true,row["master_replacement_permitted"] as? Bool == false,
                  let parts = row["parts"] as? [[String:Any]],(1...6).contains(parts.count),
                  let reference = row["original_reference_file"] as? [String:Any],
                  let referencePath = reference["local_path"] as? String,let referenceHash = reference["expected_sha256"] as? String,
                  ModelStatusReader.isHash(referenceHash,length:64),let goal = row["new_h3_action_goal"] as? String else {
                throw StudioError.invalid("镜头准备清单的顺序、身份参考或授权不完整。")
            }
            _ = try H3Files.safe(referencePath)
            guard runtime.mode == .mock ? referencePath.hasPrefix(runtime.workDirectory + "/") : referencePath.hasPrefix(AppIdentity.originalProject + "/assets/") else {
                throw StudioError.invalid("清单参考路径不属于核准素材目录。")
            }
            let referenceMatches = (try? WorkspaceDigest.sha256(URL(fileURLWithPath:referencePath))) == referenceHash
            for (partIndex,part) in parts.enumerated() {
                guard let request = part["request_id"] as? String,request.utf8.count <= 160,
                      request.hasPrefix(String(format:"planned-S%02d-p%02d-",shot,partIndex+1)),requests.insert(request).inserted,
                      part["part"] as? Int == partIndex+1,part["native_launch_ready"] as? Bool == false,
                      part["automatic_retry_count"] as? Int == 0,
                      let input = part["first_image"] as? [String:Any],input["automatic_original_artwork_substitute_allowed"] as? Bool == false,
                      let profileObject = part["native_profile"] as? [String:Any],
                      let seed = part["seed"] as? Int,(0...Int(UInt32.max)).contains(seed),
                      let selected = part["selected_raw_half_open"] as? [Int],selected.count == 2,
                      let destination = part["output_global_half_open"] as? [Int],destination.count == 2,
                      let promptPath = part["prompt_path"] as? String,let promptHash = part["prompt_sha256"] as? String,
                      ModelStatusReader.isHash(promptHash,length:64) else { throw StudioError.invalid("清单短段身份、输入策略或参数不完整。") }
                let profile = try JSONDecoder().decode(H3Profile.self,from:JSONSerialization.data(withJSONObject:profileObject))
                guard profile.width == 768,profile.height == 448,profile.fps == 24,profile.steps == 4,
                      profile.memory_cap_mb == 12288,profile.wired_pool_mb == 8192,
                      [73,90,124,141].contains(profile.frames),selected[0] >= 0,selected[1] <= profile.frames,selected[1] > selected[0],
                      destination[1] > destination[0],destination[1]-destination[0] == selected[1]-selected[0] else {
                    throw StudioError.invalid("清单原生长度、选择窗口或资源边界不匹配。")
                }
                let promptURL = try H3Files.inside(promptPath,runtime.workDirectory + "/proposals")
                let promptBytes = try H3Files.read(promptURL,limit:32768)
                guard H3ABConfigurationReader.digest(promptBytes) == promptHash,let prompt = String(data:promptBytes,encoding:.utf8) else {
                    throw StudioError.invalid("清单提示词缺失或指纹变化。")
                }
                let sourcePath = input["source_media_path"] as? String,sourceHash = input["source_media_sha256"] as? String
                let sourceIndex = input["provisional_global_frame_index"] as? Int
                let dependency = input["source_part_request_id"] as? String,rawIndex = input["source_raw_index"] as? Int
                if let dependency {
                    guard dependency != request,requests.contains(dependency),let rawIndex,rawIndex >= 0,
                          input["exact_selected_endpoint_required"] as? Bool == true,
                          sourcePath == nil,sourceIndex == nil else { throw StudioError.invalid("续段没有绑定已规划前段的精确端点。") }
                    guard let previous = jobs.first(where:{ $0.h3QueuePlan?.requestID == dependency })?.h3QueuePlan,
                          previous.shot == shot,previous.part == partIndex,previous.selectedRawEnd-1 == rawIndex else {
                        throw StudioError.invalid("续段端点不是本镜头前段选择窗口的精确末帧。")
                    }
                } else {
                    guard sourcePath == masterPath,sourceHash == masterHash,let sourceIndex,(0..<masterFrames).contains(sourceIndex),
                          input["exact_frame_index_required"] as? Bool == true else { throw StudioError.invalid("首段必须明确绑定当前母片的实际帧位。") }
                }
                let detailed = part["detailed_first_segment_contract"] as? String
                if let detailed { _ = try H3Files.inside(detailed,runtime.workDirectory + "/proposals") }
                let plan = H3QueuePlan(requestID:request,manifestSHA256:hash,shot:shot,part:partIndex+1,partCount:parts.count,
                    priority:rowIndex+1,actionGoal:goal,identityReferencePath:referencePath,identityReferenceSHA256:referenceHash,
                    identityReferenceMatches:referenceMatches,sourceMediaPath:sourcePath,sourceMediaSHA256:sourceHash,sourceGlobalFrameIndex:sourceIndex,
                    dependencyRequestID:dependency,dependencyRawIndex:rawIndex,promptPath:promptPath,promptSHA256:promptHash,profile:profile,seed:seed,
                    selectedRawStart:selected[0],selectedRawEnd:selected[1],destinationStart:destination[0],destinationEnd:destination[1],detailedFirstContractPath:detailed)
                var job = ShotJob(shot:shot,segment:String(format:"s%02d-p%02d",shot,partIndex+1),
                    title:String(format:"S%02d · 第%d/%d段",shot,partIndex+1,parts.count),prompt:prompt,
                    requestedDuration:Double(selected[1]-selected[0])/24,engine:.h3,status:.blocked)
                job.importKey = "app-planned:" + request;job.h3QueuePlan = plan
                job.stage = dependency == nil ? "待准备实际首帧 · 已登记计划" : "等待前段端点与画面检查"
                job.parameters = .init(width:768,height:448,frames:profile.frames,steps:4,fps:24,model:"MiniMax H3 FL2VA 8-bit / Turbo LoRA v4",verified:false)
                job.logTail = ["App 清单待办：\(request)。" + plan.blocker,"原 PNG 仅为身份参考，未作为生成输入；本段未准备、未领取、未生成。"]
                jobs.append(job)
            }
        }
        guard jobs.count == 33 else { throw StudioError.invalid("清单短段数量与33段摘要不同。") }
        return .init(data:data,hash:hash,jobs:jobs)
    }
}

extension TaskStore {
    @discardableResult func importPlannedQueue(_ url: URL) async throws -> Int {
        guard !shuttingDown,!abConfigurationBusy,storageFault == nil else { throw StudioError.invalid("正在保存或核对任务，请稍后再导入清单。") }
        configurationReadOperation = "读取后续镜头计划 · App-queue-manifest.local.json"
        abConfigurationBusy = true;defer { abConfigurationBusy = false }
        let runtime = h3Runtime
        let read = try await Task.detached(priority:.utility) { try H3QueueReader.load(url,runtime:runtime) }.value
        guard !shuttingDown else { throw StudioError.invalid("应用已开始退出，清单未导入。") }
        var additions: [ShotJob] = [],attachments: [(Int,H3QueuePlan)] = []
        let directory = root.appendingPathComponent("h3-queue"),snapshot = directory.appendingPathComponent(read.hash + ".json")
        _ = try H3Files.inside(snapshot.path,root.path + "/h3-queue")
        for var job in read.jobs {
            let request = job.h3QueuePlan!.requestID
            if let existing = state.jobs.first(where:{ $0.h3QueuePlan?.requestID == request }) {
                guard existing.h3QueuePlan?.manifestSHA256 == read.hash else { throw StudioError.invalid("相同请求身份的清单内容已变化，原任务保留。") }
                continue
            }
            job.h3QueuePlan?.manifestSnapshotPath = snapshot.path
            if let index = state.jobs.firstIndex(where:{ $0.externalHistory == nil && $0.shot == job.shot && $0.segment == job.segment
                && $0.h3FirstProposal?.sourcePath == job.h3QueuePlan?.detailedFirstContractPath }) {
                attachments.append((index,job.h3QueuePlan!))
            } else { additions.append(job) }
        }
        guard state.jobs.count + additions.count <= 2000 else { throw StudioError.invalid("清单导入会超出工作区记录上限。") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:snapshot.path) {
            guard try WorkspaceDigest.sha256(snapshot) == read.hash else { throw StudioError.invalid("App 保存的清单快照指纹不同。") }
        } else { try read.data.write(to:snapshot,options:.withoutOverwriting) }
        let before = state,selection = selectedID
        for (index,plan) in attachments { state.jobs[index].h3QueuePlan = plan }
        state.jobs.append(contentsOf:additions)
        if let first = additions.first { selectedID = first.id }
        persist()
        if let fault = storageFault { state = before;selectedID = selection;throw StudioError.invalid(fault) }
        notice = additions.isEmpty ? "后续镜头计划已在队列中，没有重复添加或启动。" : "已登记17镜、33段计划，本次新增\(additions.count)条。缺首帧和依赖端点的任务保持待准备，没有生成。"
        return additions.count
    }
}
