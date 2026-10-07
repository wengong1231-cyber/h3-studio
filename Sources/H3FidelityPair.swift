import Foundation
import ImageIO

// Different start/end poses are diagnostic inputs on the existing task. They
// never replace its frozen production proposal or create a new queue row.
struct H3FidelityPairPlan: Codable, Equatable {
    var schema = "jingsheng-fidelity-pair-plan-v1"
    var appJobID: UUID
    var sourceJobSHA256: String
    var firstOriginalSHA256: String
    var lastOriginalPath: String
    var lastOriginalSHA256: String
    var lastWidth: Int
    var lastHeight: Int
    var prompt: String
    var purpose: String
    var changedCondition: String
    var promptSHA256: String { H3ABConfigurationReader.digest(Data(prompt.utf8)) }
    var configurationSHA256: String {
        H3ABConfigurationReader.digest(Data((firstOriginalSHA256 + "\n" + lastOriginalSHA256 + "\n" + promptSHA256).utf8))
    }
    func validate(jobID: UUID,binding: H3Binding) throws {
        guard schema == "jingsheng-fidelity-pair-plan-v1",appJobID == jobID,
              binding.appTaskID == jobID,binding.runtime == .real,sourceJobSHA256 == binding.jobSHA256,
              firstOriginalSHA256 == binding.appFirstTask?.proposal.input?.originalSHA256,
              ModelStatusReader.isHash(lastOriginalSHA256,length:64),lastOriginalSHA256 != firstOriginalSHA256,
              (1...8192).contains(lastWidth),(1...8192).contains(lastHeight),lastWidth * lastHeight <= 67_108_864,
              (40...12000).contains(prompt.utf8.count),(12...2000).contains(purpose.utf8.count),
              (12...2000).contains(changedCondition.utf8.count) else {
            throw StudioError.invalid("不同姿态对照需要本任务原始A、不同的完整B、准确动作Prompt及条件变化说明。")
        }
        _ = try H3Files.safe(lastOriginalPath)
    }
}

struct H3FidelityPairImage: Codable, Equatable {
    var path: String
    var sha256: String
    var width: Int
    var height: Int
    func validate(inside directory: String) throws {
        _ = try H3Files.inside(path,directory)
        try H3SourceFrames.technicalImage(path,hash:sha256,width:width,height:height)
    }
}

struct H3FidelityPairTransform: Codable, Equatable {
    var algorithm = "CPU-vImage-Lanczos-contain-sRGB-black-padding"
    var scale: Double
    var translation: [Double]
    var padding: [Double]
}

struct H3FidelityPairReceipt: Codable, Equatable {
    var schema = "jingsheng-App-fidelity-pair-preparation-v1"
    var id: UUID
    var plan: H3FidelityPairPlan
    var planSHA256: String
    var previousJobSHA256: String
    var firstOriginal: H3FidelityPairImage
    var lastOriginal: H3FidelityPairImage
    var firstNormalized: H3FidelityPairImage
    var lastNormalized: H3FidelityPairImage
    var firstTransform: H3FidelityPairTransform
    var lastTransform: H3FidelityPairTransform
    var recordedAt: Date
    var videoAccepted = false
    var generationStarted = false
    var images: [H3FidelityPairImage] { [firstOriginal,firstNormalized,lastOriginal,lastNormalized] }
}

struct H3FidelityPairReview: Codable, Equatable {
    struct Check: Codable, Equatable {
        var id: String
        var status: String
        var observation: String
    }
    static let requiredChecks: Set<String> = ["identity-and-head-direction","anatomy-and-grip","composition-and-normalization","endpoint-action-and-prompt"]
    var schema = "jingsheng-fidelity-pair-input-review-v1"
    var appJobID: UUID
    var preparationID: UUID
    var preparationSHA256: String
    var promptSHA256: String
    var actor = "assistant"
    var status: String
    var observedImages: [H3FidelityPairImage]
    var checks: [Check]
    var scope = "input-pixels-only"
    var videoAccepted = false
    func validate(pair: H3FidelityPairBinding) throws {
        guard schema == "jingsheng-fidelity-pair-input-review-v1",appJobID == pair.receipt.plan.appJobID,
              preparationID == pair.id,preparationSHA256 == pair.receiptSHA256,
              promptSHA256 == pair.receipt.plan.promptSHA256,actor == "assistant",scope == "input-pixels-only",!videoAccepted,
              ["pass","fail"].contains(status),observedImages == pair.receipt.images,
              checks.count == Self.requiredChecks.count,Set(checks.map(\.id)) == Self.requiredChecks,
              checks.allSatisfy({ ["pass","fail"].contains($0.status) && (12...3000).contains($0.observation.utf8.count) }),
              (status == "pass") == checks.allSatisfy({ $0.status == "pass" }) else {
            throw StudioError.invalid("助手图审必须实际检查本次两张原图、两张归一图及Prompt，不能代替视频验收。")
        }
    }
}

struct H3FidelityPairReviewBinding: Codable, Equatable {
    var path: String
    var sha256: String
    var status: String
    var importedAt: Date
}

struct H3FidelityPairBinding: Codable, Equatable, Identifiable {
    var receipt: H3FidelityPairReceipt
    var receiptPath: String
    var receiptSHA256: String
    var reviews: [H3FidelityPairReviewBinding] = []
    var id: UUID { receipt.id }
    var directory: String { URL(fileURLWithPath:receiptPath).deletingLastPathComponent().path }
    var reviewed: Bool { reviews.last?.status == "pass" }
    func validate(jobID: UUID,binding: H3Binding,workspace: String,requireReview: Bool) throws {
        try receipt.plan.validate(jobID:jobID,binding:binding)
        let expected = workspace + "/h3-fidelity-inputs/" + jobID.uuidString + "/" + id.uuidString
        guard directory == expected,receiptPath == expected + "/preparation.json",
              receipt.schema == "jingsheng-App-fidelity-pair-preparation-v1",!receipt.videoAccepted,!receipt.generationStarted else {
            throw StudioError.invalid("不同姿态输入回执的任务或目录不符。")
        }
        let bytes = try H3Files.read(H3Files.inside(receiptPath,expected))
        let planBytes = try H3Files.read(H3Files.inside(expected + "/plan.json",expected))
        let previous = try H3Files.read(H3Files.inside(expected + "/previous-job.json",expected),limit:20_971_520)
        let old = try JSONDecoder().decode(ShotJob.self,from:previous)
        guard H3ABConfigurationReader.digest(bytes) == receiptSHA256,
              try JSONDecoder().decode(H3FidelityPairReceipt.self,from:bytes) == receipt,
              H3ABConfigurationReader.digest(planBytes) == receipt.planSHA256,
              try JSONDecoder().decode(H3FidelityPairPlan.self,from:planBytes) == receipt.plan,
              H3ABConfigurationReader.digest(previous) == receipt.previousJobSHA256,
              old.id == jobID,old.h3Binding?.jobSHA256 == binding.jobSHA256,
              receipt.firstOriginal.sha256 == receipt.plan.firstOriginalSHA256,
              receipt.lastOriginal.sha256 == receipt.plan.lastOriginalSHA256,
              receipt.firstNormalized.width == 1536,receipt.firstNormalized.height == 896,
              receipt.lastNormalized.width == 1536,receipt.lastNormalized.height == 896,
              receipt.firstNormalized.sha256 != receipt.lastNormalized.sha256,
              try H3Files.read(H3Files.inside(expected + "/motion-prompt.txt",expected)) == Data(receipt.plan.prompt.utf8) else {
            throw StudioError.invalid("不同姿态输入、原任务历史、Prompt或归一回执已改变。")
        }
        for image in receipt.images { try image.validate(inside:expected) }
        for review in reviews {
            let data = try H3Files.read(H3Files.inside(review.path,expected + "/reviews"))
            let value = try JSONDecoder().decode(H3FidelityPairReview.self,from:data)
            guard H3ABConfigurationReader.digest(data) == review.sha256,value.status == review.status else {
                throw StudioError.invalid("助手输入图审指纹发生变化。")
            }
            try value.validate(pair:self)
        }
        guard !requireReview || reviewed else { throw StudioError.invalid("先完成不同A/B原图与归一图的助手图审，再启动短段。") }
    }
}

enum H3FidelityPair {
    static func prepare(planBytes: Data,job: ShotJob,workspace: String) throws -> H3FidelityPairBinding {
        let plan = try JSONDecoder().decode(H3FidelityPairPlan.self,from:planBytes)
        guard let binding = job.h3Binding,let input = binding.appFirstTask?.proposal.input else { throw StudioError.invalid("缺少本任务原始A绑定。") }
        try plan.validate(jobID:job.id,binding:binding)
        guard job.h3FidelityPairs?.contains(where:{ $0.receipt.plan.configurationSHA256 == plan.configurationSHA256 }) != true else {
            throw StudioError.invalid("相同A/B和Prompt已经准备，复用既有图审与历史，不重复导入。")
        }
        let verified = try H3FirstTaskBinding.load(H3Files.safe(binding.jobPath),runtime:.real,requireFresh:false,allowHistoricalAcceptance:true).0
        guard verified.jobSHA256 == binding.jobSHA256 else { throw StudioError.invalid("原任务身份变化。") }
        return try freeze(planBytes:planBytes,plan:plan,job:job,input:input,workspace:workspace)
    }
    // Separate CPU-only preparation permits isolated fixtures; the UI entry
    // above always validates the real frozen source task first.
    static func freeze(planBytes: Data,plan: H3FidelityPairPlan,job: ShotJob,input: H3FirstInput,workspace: String) throws -> H3FidelityPairBinding {
        let id = UUID(),directory = try H3Files.inside(workspace + "/h3-fidelity-inputs/" + job.id.uuidString + "/" + id.uuidString,workspace)
        try H3SourceFrames.technicalImage(input.originalPath,hash:input.originalSHA256,width:input.originalWidth,height:input.originalHeight)
        try H3SourceFrames.technicalImage(plan.lastOriginalPath,hash:plan.lastOriginalSHA256,width:plan.lastWidth,height:plan.lastHeight)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        let previous = try encoder.encode(job)
        try previous.write(to:directory.appendingPathComponent("previous-job.json"),options:.withoutOverwriting)
        try planBytes.write(to:directory.appendingPathComponent("plan.json"),options:.withoutOverwriting)
        try Data(plan.prompt.utf8).write(to:directory.appendingPathComponent("motion-prompt.txt"),options:.withoutOverwriting)
        func normalize(_ path: String,_ hash: String,_ prefix: String) throws -> (H3FidelityPairImage,H3FidelityPairImage,H3FidelityPairTransform) {
            let data = try H3Files.read(H3Files.safe(path),limit:50_331_648)
            guard H3ABConfigurationReader.digest(data) == hash,let source = CGImageSourceCreateWithData(data as CFData,nil),
                  let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw StudioError.invalid("A/B像素读取期间变化。") }
            let original = directory.appendingPathComponent(prefix + "-original.png"),normalized = directory.appendingPathComponent(prefix + "-normalized.png")
            try data.write(to:original,options:.withoutOverwriting)
            let result = try H3SourceFrames.contain(image,canvasWidth:1536,canvasHeight:896)
            try H3SourceFrames.save(result.image,to:normalized)
            return (.init(path:original.path,sha256:hash,width:image.width,height:image.height),
                    .init(path:normalized.path,sha256:try WorkspaceDigest.sha256(normalized),width:1536,height:896),
                    .init(scale:result.scale,translation:result.translation,padding:result.padding))
        }
        let a = try normalize(input.originalPath,input.originalSHA256,"A"),b = try normalize(plan.lastOriginalPath,plan.lastOriginalSHA256,"B")
        let receipt = H3FidelityPairReceipt(id:id,plan:plan,planSHA256:H3ABConfigurationReader.digest(planBytes),previousJobSHA256:H3ABConfigurationReader.digest(previous),firstOriginal:a.0,lastOriginal:b.0,firstNormalized:a.1,lastNormalized:b.1,firstTransform:a.2,lastTransform:b.2,recordedAt:Date())
        let bytes = try encoder.encode(receipt),path = directory.appendingPathComponent("preparation.json")
        try bytes.write(to:path,options:.withoutOverwriting)
        return .init(receipt:receipt,receiptPath:path.path,receiptSHA256:H3ABConfigurationReader.digest(bytes))
    }
    static func used(_ pair: H3FidelityPairBinding,in job: ShotJob) -> Bool {
        job.h3FidelityChecks?.contains(where:{ $0.pairedInput?.receipt.plan.configurationSHA256 == pair.receipt.plan.configurationSHA256 }) == true
    }
}

extension TaskStore {
    func canPrepareFidelityPair(_ id: UUID) -> Bool {
        guard singleGeneratorIdle,h3Runtime.mode == .real,let job = state.jobs.first(where:{ $0.id == id }),
              job.externalHistory == nil,job.supersededBy == nil,job.status == .completed,job.h3VideoRejection != nil,
              let proposal = job.h3Binding?.appFirstTask?.proposal,proposal.reviewReady,let original = proposal.input?.originalSHA256 else { return false }
        return H3Fidelity.comparisonBaseline(for:.motionPairedKeyframes,in:job,originalSHA256:original) != nil
    }
    func importFidelityPair(_ url: URL,jobID: UUID) async throws {
        guard canPrepareFidelityPair(jobID),let i = state.jobs.firstIndex(where:{ $0.id == jobID }) else { throw StudioError.invalid("先保留已失败的首尾同图对照；生成空闲时准备不同姿态。") }
        let job = state.jobs[i],workspace = root.path,bytes = try H3Files.read(H3Files.safe(url.path),limit:131_072)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(job)
        fidelityJobID = jobID;fidelityPreparing = true
        defer { fidelityJobID = nil;fidelityPreparing = false }
        let pair = try await Task.detached(priority:.utility) { try H3FidelityPair.prepare(planBytes:bytes,job:job,workspace:workspace) }.value
        guard !shuttingDown,fidelityJobID == jobID,let index = state.jobs.firstIndex(where:{ $0.id == jobID }),
              try encoder.encode(state.jobs[index]) == before else { throw StudioError.invalid("准备期间任务变化；保留输入文件，未替换任务。") }
        try pair.validate(jobID:jobID,binding:job.h3Binding!,workspace:workspace,requireReview:false)
        if state.jobs[index].h3FidelityPairs == nil { state.jobs[index].h3FidelityPairs = [] }
        state.jobs[index].h3FidelityPairs?.append(pair)
        state.jobs[index].logTail.append("App已准备不同A/B关键姿态及1536完整归一图，等待助手输入图审；原候选、Prompt和拒绝均保留，未启动GPU。")
        persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        notice = "不同A/B已归一，接下来检查两张原图、两张归一图及Prompt。"
    }
    func importFidelityPairReview(_ url: URL,jobID: UUID) throws {
        guard canPrepareFidelityPair(jobID),let i = state.jobs.firstIndex(where:{ $0.id == jobID }),
              let j = state.jobs[i].h3FidelityPairs?.indices.last,var pair = state.jobs[i].h3FidelityPairs?[j],
              let binding = state.jobs[i].h3Binding,!H3FidelityPair.used(pair,in:state.jobs[i]) else { throw StudioError.invalid("助手图审只适用于尚未尝试的当前A/B准备，不能改写运行历史。") }
        try pair.validate(jobID:jobID,binding:binding,workspace:root.path,requireReview:false)
        let bytes = try H3Files.read(H3Files.safe(url.path),limit:131_072),review = try JSONDecoder().decode(H3FidelityPairReview.self,from:bytes)
        try review.validate(pair:pair)
        let hash = H3ABConfigurationReader.digest(bytes)
        guard !pair.reviews.contains(where:{ $0.sha256 == hash }) else { throw StudioError.invalid("此助手图审已经保存，无需重复导入。") }
        let directory = try H3Files.inside(pair.directory + "/reviews",pair.directory)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let path = directory.appendingPathComponent(UUID().uuidString + ".json")
        try bytes.write(to:path,options:.withoutOverwriting)
        pair.reviews.append(.init(path:path.path,sha256:hash,status:review.status,importedAt:Date()))
        try pair.validate(jobID:jobID,binding:binding,workspace:root.path,requireReview:false)
        state.jobs[i].h3FidelityPairs?[j] = pair
        state.jobs[i].logTail.append("不同A/B助手输入图审：" + review.status + "；仅记录输入检查，没有接受视频或自动启动生成。")
        persist();guard storageFault == nil else { throw StudioError.invalid(storageFault!) }
        notice = review.status == "pass" ? "A/B输入图审通过，可启动不同首尾姿态短段对照。" : "A/B输入检查未通过，先修订具体差异。"
    }
}
