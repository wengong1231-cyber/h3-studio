import Foundation

/// An App click identifies an input path, not the person who produced it.
/// Explicit product actions and external instructions keep different origins.
struct H3AcceptanceProvenance: Codable, Equatable {
    var origin: String
    var actorKind: String
    var sourceReference: String?
    var instructionPath: String?
    var instructionSHA256: String?
    var continuationAuthorized: Bool? = nil
    var uiActionID: UUID? = nil
    var uiActionPath: String? = nil
    var uiActionSHA256: String? = nil
    var successorAppJobID: UUID? = nil
    var successorRequestID: String? = nil

    static var unidentifiedUI: Self { .init(origin:"app_ui",actorKind:"unknown") }
    static var fixture: Self { .init(origin:"cpu_fixture",actorKind:"fixture",continuationAuthorized:true) }
    var declaresUserInstruction: Bool {
        origin == "external_user_instruction" && actorKind == "user"
            && sourceReference.map { (8...2000).contains($0.utf8.count) } == true
            && instructionPath != nil && instructionSHA256.map { ModelStatusReader.isHash($0,length:64) } == true
    }
}

struct H3UserVideoAcceptanceInstruction: Codable, Equatable {
    var schema = "jingsheng-App-user-video-acceptance-instruction-v1"
    var appJobID: UUID
    var requestID: String
    var nativeJobSHA256: String
    var clipSHA256: String
    var reportSHA256: String
    var selectedRawHalfOpen: [Int]
    var endpointRawIndex: Int
    var endpointSHA256: String
    var sourceReference: String
    var actorKind: String
    var explicitUserAcceptance: Bool
    var selectedWindowViewed: Bool
    var endpointPixelsViewed: Bool
    var observation: String
    var knownVisualRisks: [String]
    var instructedAt: Date
    var authorizeContinuation: Bool? = nil

    func validate(against review: H3QueueEndpointReview) throws {
        guard schema == "jingsheng-App-user-video-acceptance-instruction-v1",actorKind == "user",explicitUserAcceptance,
              selectedWindowViewed,endpointPixelsViewed,(8...2000).contains(sourceReference.utf8.count),
              !sourceReference.hasPrefix("AppUI_"),(12...4000).contains(observation.utf8.count),
              knownVisualRisks.count <= 20,knownVisualRisks.allSatisfy({ (1...1000).contains($0.utf8.count) }),
              appJobID == review.appJobID,requestID == review.requestID,nativeJobSHA256 == review.nativeJobSHA256,
              clipSHA256 == review.clipSHA256,reportSHA256 == review.reportSHA256,
              selectedRawHalfOpen == review.selectedRawHalfOpen,endpointRawIndex == review.endpointRawIndex,
              endpointSHA256 == review.endpointSHA256 else {
            throw StudioError.invalid("外部接受指令必须明确来自用户，并绑定当前候选、所选窗口、端帧和可追溯来源。")
        }
    }
}

enum H3AcceptanceAuthority {
    static func valid(_ review: H3QueueEndpointReview,workspace: URL,runtime: H3Runtime,requireContinuation: Bool = false,
                      successorAppJobID: UUID? = nil,successorRequestID: String? = nil) throws -> Bool {
        if review.provenance?.declaresProductAcceptance == true {
            return try validUIAction(review,workspace:workspace,requireContinuation:requireContinuation,
                successorAppJobID:successorAppJobID,successorRequestID:successorRequestID)
        }
        if runtime.mode == .mock {
            return review.reviewerKind == "fixture" && (review.provenance == nil || review.provenance == .fixture)
        }
        guard review.reviewerKind == "user",review.acceptanceSource == "external_user_instruction",
              let provenance = review.provenance,provenance.declaresUserInstruction,
              let path = provenance.instructionPath,let hash = provenance.instructionSHA256 else { return false }
        let url = try H3Files.inside(path,workspace.path + "/h3-queue-reviews/" + review.appJobID.uuidString + "/acceptance-instructions")
        let bytes = try H3Files.read(url,limit:32768)
        guard H3ABConfigurationReader.digest(bytes) == hash else { return false }
        let decoder = JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let instruction = try decoder.decode(H3UserVideoAcceptanceInstruction.self,from:bytes)
        try instruction.validate(against:review)
        return instruction.sourceReference == provenance.sourceReference
            && (!requireContinuation || (instruction.authorizeContinuation == true && provenance.continuationAuthorized == true))
    }
}
