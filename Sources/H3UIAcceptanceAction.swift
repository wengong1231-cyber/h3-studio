import Foundation

/// An explicit product action, not an assertion about the human/agent identity
/// or independently observed viewing. Its immutable event binds one candidate
/// and one successor revision, so a later redo cannot inherit the action.
struct H3UIVideoAcceptanceAction: Codable, Equatable {
    var schema = "jingsheng-App-ui-video-acceptance-action-v1"
    var id = UUID()
    var origin = "app_ui"
    var actorKind = "unknown"
    var explicitAcceptance = true
    var appJobID: UUID
    var requestID: String
    var nativeJobSHA256: String
    var clipSHA256: String
    var reportSHA256: String
    var selectedRawHalfOpen: [Int]
    var endpointRawIndex: Int
    var endpointSHA256: String
    var actionRevisionNumber: Int
    var promptSHA256: String
    var staticBindingSHA256: String?
    var authorizeContinuation: Bool
    var successorAppJobID: UUID?
    var successorRequestID: String?
    var recordedAt: Date
    func validate(against review: H3QueueEndpointReview) throws {
        guard schema == "jingsheng-App-ui-video-acceptance-action-v1",origin == "app_ui",actorKind == "unknown",explicitAcceptance,
              review.reviewerKind == "unknown",review.acceptanceSource == "app_ui_explicit_acceptance",
              appJobID == review.appJobID,requestID == review.requestID,nativeJobSHA256 == review.nativeJobSHA256,
              clipSHA256 == review.clipSHA256,reportSHA256 == review.reportSHA256,
              selectedRawHalfOpen == review.selectedRawHalfOpen,endpointRawIndex == review.endpointRawIndex,endpointSHA256 == review.endpointSHA256,
              actionRevisionNumber == review.actionRevisionNumber,promptSHA256 == review.acceptancePromptSHA256,
              staticBindingSHA256 == review.acceptanceStaticBindingSHA256,(1...100).contains(actionRevisionNumber),
              [nativeJobSHA256,clipSHA256,reportSHA256,endpointSHA256,promptSHA256].allSatisfy({ ModelStatusReader.isHash($0,length:64) }),
              !authorizeContinuation || (successorAppJobID != nil && successorRequestID.map { !$0.isEmpty } == true) else {
            throw StudioError.invalid("界面接受操作未绑定当前视频、端帧、版本或续段关系。")
        }
    }
}

extension H3AcceptanceProvenance {
    var declaresProductAcceptance: Bool {
        origin == "app_ui_explicit_acceptance" && actorKind == "unknown" && uiActionID != nil && uiActionPath != nil
            && uiActionSHA256.map { ModelStatusReader.isHash($0,length:64) } == true
            && (continuationAuthorized != true || (successorAppJobID != nil && successorRequestID != nil))
    }
}

extension H3AcceptanceAuthority {
    static func validUIAction(_ review: H3QueueEndpointReview,workspace: URL,requireContinuation: Bool,
                              successorAppJobID: UUID?,successorRequestID: String?) throws -> Bool {
        guard let provenance = review.provenance,provenance.declaresProductAcceptance,
              let path = provenance.uiActionPath,let hash = provenance.uiActionSHA256 else { return false }
        let url = try H3Files.inside(path,workspace.path + "/h3-queue-reviews/" + review.appJobID.uuidString + "/ui-acceptance-actions")
        let bytes = try H3Files.read(url,limit:32768)
        guard H3ABConfigurationReader.digest(bytes) == hash else { return false }
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let action = try decoder.decode(H3UIVideoAcceptanceAction.self,from:bytes)
        try action.validate(against:review)
        guard action.id == provenance.uiActionID,action.authorizeContinuation == (provenance.continuationAuthorized == true),
              action.successorAppJobID == provenance.successorAppJobID,action.successorRequestID == provenance.successorRequestID else { return false }
        if requireContinuation {
            guard action.authorizeContinuation else { return false }
            if let successorAppJobID,action.successorAppJobID != successorAppJobID { return false }
            if let successorRequestID,action.successorRequestID != successorRequestID { return false }
        }
        return true
    }
}

extension H3VideoReviewReader {
    static func recordUIAction(_ review: inout H3QueueEndpointReview,job: ShotJob,workspace: URL,continueNext: Bool,successor: ShotJob?) throws {
        let continuation = continueNext && successor?.h3QueuePlan?.dependencyRequestID == job.h3QueuePlan?.requestID
            && successor?.supersededBy == nil && successor != nil
        let action = H3UIVideoAcceptanceAction(appJobID:job.id,requestID:review.requestID,nativeJobSHA256:review.nativeJobSHA256,
            clipSHA256:review.clipSHA256,reportSHA256:review.reportSHA256,selectedRawHalfOpen:review.selectedRawHalfOpen,
            endpointRawIndex:review.endpointRawIndex,endpointSHA256:review.endpointSHA256,actionRevisionNumber:job.actionRevisionNumber,
            promptSHA256:job.h3FirstProposal?.promptSHA256 ?? job.h3QueuePlan!.promptSHA256,staticBindingSHA256:job.h3StaticBinding?.recordSHA256,
            authorizeContinuation:continuation,successorAppJobID:continuation ? successor?.id : nil,
            successorRequestID:continuation ? successor?.h3QueuePlan?.requestID : nil,recordedAt:Date())
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let bytes = try encoder.encode(action)
        let path = workspace.appendingPathComponent("h3-queue-reviews/" + job.id.uuidString + "/ui-acceptance-actions/" + action.id.uuidString + ".json")
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try bytes.write(to:path,options:.withoutOverwriting)
        review.status = "pass";review.reviewerKind = "unknown";review.acceptanceSource = "app_ui_explicit_acceptance"
        review.userEvidenceID = "UIAction_" + action.id.uuidString
        review.actionRevisionNumber = action.actionRevisionNumber;review.acceptancePromptSHA256 = action.promptSHA256
        review.acceptanceStaticBindingSHA256 = action.staticBindingSHA256
        // These remain false: the App did not independently verify viewing.
        review.selectedWindowViewed = false;review.endpointPixelsViewed = false
        review.observation = continuation ? "应用中明确接受本段所选候选与原生端帧，并继续已绑定的下一段。来源为界面操作；操作者身份未认证。" : "应用中明确接受本段所选候选与原生端帧。来源为界面操作；操作者身份未认证。"
        review.provenance = .init(origin:"app_ui_explicit_acceptance",actorKind:"unknown",sourceReference:"UIAction_" + action.id.uuidString,
            continuationAuthorized:continuation,uiActionID:action.id,uiActionPath:path.path,uiActionSHA256:H3ABConfigurationReader.digest(bytes),
            successorAppJobID:action.successorAppJobID,successorRequestID:action.successorRequestID)
    }
}
