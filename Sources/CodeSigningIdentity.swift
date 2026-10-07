import Foundation
import Security
import CryptoKit

struct CodeSigningIdentity: Codable, Equatable {
    var identifier: String
    var designatedRequirement: String
    var certificateSHA256: [String]
    var isAdHoc: Bool
    var leafCertificateSHA1: String? = nil

    var hasPersistentIdentity: Bool {
        guard identifier == AppIdentity.bundleID,!isAdHoc,!certificateSHA256.isEmpty,
              let leafCertificateSHA1,ModelStatusReader.isHash(leafCertificateSHA1,length:40) else { return false }
        return designatedRequirement == "identifier \"" + identifier + "\" and certificate leaf = H\"" + leafCertificateSHA1.lowercased() + "\""
    }

    static func inspect(_ app: URL) throws -> CodeSigningIdentity {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw StudioError.invalid("无法读取应用签名身份，未安装。")
        }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue:kSecCSStrictValidate), nil) == errSecSuccess else {
            throw StudioError.invalid("应用签名或资源校验失败，未安装。")
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String else {
            throw StudioError.invalid("应用缺少可核对的签名身份，未安装。")
        }
        var requirementText: CFString?
        if let requirement = values[kSecCodeInfoDesignatedRequirement as String] {
            guard SecRequirementCopyString(requirement as! SecRequirement, [], &requirementText) == errSecSuccess else {
                throw StudioError.invalid("无法读取应用身份要求，未安装。")
            }
        }
        var certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        // Local self-signed certificates need no global trust. macOS can omit
        // the convenience certificates array while still exposing the actual
        // signing chain on its trust object. Read it without modifying trust.
        if certificates.isEmpty, let trust = values[kSecCodeInfoTrust as String] {
            certificates = SecTrustCopyCertificateChain(trust as! SecTrust) as? [SecCertificate] ?? []
        }
        let hashes = certificates.map { certificate in
            SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        }
        let signatureFlags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return .init(identifier: identifier, designatedRequirement: requirementText as String? ?? "",
                     certificateSHA256: hashes, isAdHoc: signatureFlags & 0x2 != 0,
                     leafCertificateSHA1:certificates.first.map { Insecure.SHA1.hash(data:SecCertificateCopyData($0) as Data).map { String(format:"%02x",$0) }.joined() })
    }

    static func satisfies(_ app: URL, requirement: String) throws -> Bool {
        var code: SecStaticCode?
        var constraint: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &constraint) == errSecSuccess,
              let code, let constraint else { throw StudioError.invalid("无法核对升级前后的签名身份。") }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), constraint) == errSecSuccess
    }

    // TCC remains exclusively managed by macOS. This only checks whether a new
    // bundle can satisfy the identity already granted to the installed bundle.
    static func validateUpgrade(candidate: CodeSigningIdentity, existing: CodeSigningIdentity?,
                                satisfiesExisting: Bool, allowInitialMigration: Bool) throws -> Bool {
        guard candidate.hasPersistentIdentity else {
            throw StudioError.invalid("正式安装需要固定证书签名；临时签名会使更新后的文件授权失效，未安装。")
        }
        guard let existing else { return false }
        guard existing.identifier == candidate.identifier else { throw StudioError.invalid("升级签名标识不一致，未安装。") }
        if existing.isAdHoc {
            guard allowInitialMigration else {
                throw StudioError.invalid("此升级将首次切换到固定签名身份，可能需要重新允许文件访问。请审查安装计划后使用 --allow-signing-identity-migration；以后不得自动更换身份。")
            }
            return true
        }
        guard existing.hasPersistentIdentity, satisfiesExisting else {
            throw StudioError.invalid("候选不满足已安装应用的签名身份要求，拒绝更换证书或回退临时签名。")
        }
        return false
    }
}
