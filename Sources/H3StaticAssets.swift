import Foundation
import ImageIO

struct H3StaticAsset: Codable, Equatable, Identifiable {
    var id: String
    var shot: Int
    var stage: String
    var path: String
    var sha256: String
    var bytes: Int
    var width: Int
    var height: Int
    var classification: String
    var motionConstraints: String
    var libraryFileID: String?

    var stageLabel: String {
        switch stage {
        case "river-valley": return "河谷"
        case "closed-eyes": return "闭目"
        case "open-eyes-original-reference": return "睁眼完成"
        case "palm-already-completely-visible": return "完整手掌 · 已在画面内"
        case "ready": return "READY 起势"
        case "full-draw": return "满弓"
        case "release": return "释放"
        default: return stage == "complete-reused-artwork" ? "完整原画" : stage
        }
    }
    func readVerified() throws -> (Data,CGImage) {
        guard (1...10000).contains(shot),(1...128).contains(stage.utf8.count),
              ModelStatusReader.isHash(sha256,length:64),(1...50_331_648).contains(bytes),
              (1...8192).contains(width),(1...8192).contains(height),width*height <= 67_108_864,
              !classification.isEmpty,motionConstraints.utf8.count <= 16000 else { throw StudioError.invalid("静态素材身份、尺寸或来源不完整。") }
        let data = try H3Files.read(H3Files.safe(path),limit:50_331_648)
        guard data.count == bytes,H3ABConfigurationReader.digest(data) == sha256,
              let source = CGImageSourceCreateWithData(data as CFData,nil),CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width == width,image.height == height else { throw StudioError.invalid("静态图已变化、不是单张完整图片或无法完整解码。") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
        guard (properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else { throw StudioError.invalid("静态图方向元数据需要受支持的完整画面转换，当前未裁切或旋转。") }
        return (data,image)
    }
    static func selected(_ url: URL,shot: Int,motion: String) throws -> Self {
        let data = try H3Files.read(H3Files.safe(url.path),limit:50_331_648)
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),let image = CGImageSourceCreateImageAtIndex(source,0,nil) else {
            throw StudioError.invalid("所选素材不是完整可解码的静态图。")
        }
        let hash = H3ABConfigurationReader.digest(data)
        let asset = Self(id:"S\(shot):selected:\(hash)",shot:shot,stage:"用户已有完整素材",path:url.path,
            sha256:hash,bytes:data.count,width:image.width,height:image.height,classification:"user_selected_complete_material_not_MV_frame",
            motionConstraints:motion)
        _ = try asset.readVerified();return asset
    }
}

struct H3StaticCatalog: Codable, Equatable, Identifiable {
    var id: String
    var sourcePath: String
    var snapshotPath: String
    var importedAt: Date
    var assets: [H3StaticAsset]
}

enum H3StaticCatalogReader {
    static var knownPath: URL {
        AppIdentity.modelStatusRoot.appendingPathComponent("inputs/remaining-h3-full-inputs-20261006-smh65j97/App-inputs-HANDOFF.local.json")
    }
    static func read(_ url: URL) throws -> (Data,[H3StaticAsset]) {
        let bytes = try H3Files.read(H3Files.safe(url.path),limit:2_097_152)
        guard let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw StudioError.invalid("需要完整静态图交接清单。") }
        if object["schema"] as? String == "jingsheng-S10-identity-action-reference-assets-handoff-v1" {
            return try readS10(bytes,object:object)
        }
        guard ["jingsheng-complete-static-input-assets-handoff-v1","jingsheng-App-static-image-catalog-v1"].contains(object["schema"] as? String ?? ""),
              let rows = object["inputs"] as? [[String:Any]],(1...128).contains(rows.count),
              let directory = object["image_directory"] as? String else { throw StudioError.invalid("需要完整静态图交接清单与图片目录。") }
        _ = try H3Files.safe(directory)
        if let count = object["image_count"] as? Int, count != rows.count { throw StudioError.invalid("图库数量与交接清单不同。") }
        var assets: [H3StaticAsset] = []
        for row in rows {
            guard let shot = row["shot"] as? Int,let stage = row["stage"] as? String,
                  let path = row["local_path"] as? String,let hash = row["sha256"] as? String,
                  let size = row["bytes"] as? Int,let dimensions = row["dimensions"] as? [Int],dimensions.count == 2,
                  let classification = row["source_classification"] as? String,
                  let motion = row["H3_motion_constraints"] as? String,(12...16000).contains(motion.utf8.count) else {
                throw StudioError.invalid("每张完整图必须有镜号、阶段、来源、SHA、尺寸与动作约束。")
            }
            _ = try H3Files.inside(path,directory)
            let library = row["source_library_file_id"] as? String ?? (row["source_library_identity"] as? [String:Any])?["library_file_id"] as? String
            let asset = H3StaticAsset(id:"S\(shot):\(stage):\(hash)",shot:shot,stage:stage,path:path,sha256:hash,bytes:size,
                width:dimensions[0],height:dimensions[1],classification:classification,motionConstraints:motion,libraryFileID:library)
            _ = try asset.readVerified();assets.append(asset)
        }
        guard Set(assets.map(\.id)).count == assets.count else { throw StudioError.invalid("图库出现重复阶段身份。") }
        let stages = assets.filter { $0.shot == 5 }.map(\.stage)
        if stages.contains("river-valley") || stages.contains("closed-eyes") || stages.contains("open-eyes-original-reference") {
            guard stages == ["river-valley","closed-eyes","open-eyes-original-reference"] else { throw StudioError.invalid("S05 必须保留河谷→闭目→睁眼的三阶段顺序。") }
        }
        return (bytes,assets)
    }
    private static func readS10(_ bytes: Data,object: [String:Any]) throws -> (Data,[H3StaticAsset]) {
        guard let rows = object["images"] as? [[String:Any]],rows.count == 3,
              let directory = object["local_image_directory"] as? String,
              let qa = object["source_QA"] as? [String:Any],let constraints = qa["h3_constraints"] as? [String],
              let limitations = qa["failed_continuity_constraints"] as? [String],let face = qa["face_reference"] as? String else {
            throw StudioError.invalid("S10 参考需要三图、身份约束和明确的非连续端点限制。")
        }
        _ = try H3Files.safe(directory)
        let stages = ["ready","full-draw","release"]
        let motion = ([face]+constraints+["These are identity/action references, not certified continuous end anchors. User face/video approval is pending."]+limitations).joined(separator:"\n")
        var assets: [H3StaticAsset] = []
        for (index,row) in rows.enumerated() {
            guard row["accepted_sequential_endpoint"] as? Bool == false,
                  let path = row["local_path"] as? String,let hash = row["sha256"] as? String,
                  let size = row["size_bytes"] as? Int,let dimensions = row["dimensions"] as? [Int],dimensions.count == 2 else {
                throw StudioError.invalid("S10 动作参考不能自动登记为连续端点。")
            }
            _ = try H3Files.inside(path,directory)
            let asset = H3StaticAsset(id:"S10:\(stages[index]):\(hash)",shot:10,stage:stages[index],path:path,sha256:hash,bytes:size,
                width:dimensions[0],height:dimensions[1],classification:"new_identity_and_action_reference_not_accepted_endpoint",
                motionConstraints:motion,libraryFileID:row["library_file_id"] as? String)
            _ = try asset.readVerified();assets.append(asset)
        }
        return (bytes,assets)
    }
}

/// An explicit allocation uses the already registered segment boundaries. The
/// materials handoff alone does not specify where S05 changes visual stage.
enum H3StaticStagePlan {
    static func validateS05(_ assignments: [(H3QueuePlan,H3StaticAsset)]) throws {
        let ordered = assignments.sorted { $0.0.part < $1.0.part }
        guard let first = ordered.first,let last = ordered.last,
              ordered.count == first.0.partCount,first.0.part == 1,last.0.part == first.0.partCount,
              first.0.destinationStart == 1564,last.0.destinationEnd == 1840 else { throw StudioError.invalid("S05 分阶段映射必须覆盖已登记的完整276帧窗口。") }
        let sequence = ["river-valley","closed-eyes","open-eyes-original-reference"]
        var previous = -1
        for (i,pair) in ordered.enumerated() {
            guard pair.0.shot == 5,pair.1.shot == 5,pair.0.part == i+1,
                  let stage = sequence.firstIndex(of:pair.1.stage),stage >= previous,
                  i == 0 || ordered[i-1].0.destinationEnd == pair.0.destinationStart else {
                throw StudioError.invalid("S05 分阶段映射倒序、缺段或不连续；没有生成。")
            }
            previous = stage
        }
        guard Set(ordered.map { $0.1.stage }) == Set(sequence) else { throw StudioError.invalid("S05 河谷、闭目和睁眼三个阶段都必须有明确窗口。") }
    }
}
