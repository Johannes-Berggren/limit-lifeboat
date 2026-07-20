import Foundation
import Security

/// Runtime classification used to decide whether a native Keychain approval
/// can survive an app rebuild/update. No certificate names or requirements are
/// retained or logged.
public enum ApplicationCodeSignatureStatus: Equatable, Sendable {
    case appleDevelopment(teamIdentifier: String)
    case developerIDApplication(teamIdentifier: String)
    case adHoc
    case unsupported
    case invalid(OSStatus)

    public func supportsDurableAuthorization(for variant: ApplicationVariant) -> Bool {
        switch (variant, self) {
        case (.development, .appleDevelopment):
            return true
        case (.distribution, .developerIDApplication):
            return true
        default:
            return false
        }
    }

    public var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}

public enum ApplicationCodeSignatureInspector {
    public static func inspect(executableURL: URL) -> ApplicationCodeSignatureStatus {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return .invalid(createStatus)
        }

        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validityStatus == errSecSuccess else {
            return .invalid(validityStatus)
        }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [String: Any] else {
            return .invalid(informationStatus)
        }

        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let subject = certificates?.first.flatMap {
            SecCertificateCopySubjectSummary($0) as String?
        }
        let classification = classify(
            signatureFlags: flags,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
            leafSubject: subject
        )
        switch classification {
        case .appleDevelopment, .developerIDApplication:
            var appleAnchor: SecRequirement?
            let requirementStatus = SecRequirementCreateWithString(
                "anchor apple generic" as CFString,
                SecCSFlags(),
                &appleAnchor
            )
            guard requirementStatus == errSecSuccess, let appleAnchor else {
                return .invalid(requirementStatus)
            }
            let anchorStatus = SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                appleAnchor
            )
            guard anchorStatus == errSecSuccess else {
                return .invalid(anchorStatus)
            }
            return classification
        case .adHoc, .unsupported, .invalid:
            return classification
        }
    }

    static func classify(
        signatureFlags: UInt32,
        teamIdentifier: String?,
        leafSubject: String?
    ) -> ApplicationCodeSignatureStatus {
        // kSecCodeSignatureAdhoc is declared in CSCommon.h but is not exposed
        // by the Swift overlay. Its documented stable bit value is 0x0002.
        if signatureFlags & 0x0002 != 0 {
            return .adHoc
        }
        guard let teamIdentifier, !teamIdentifier.isEmpty, let leafSubject else {
            return .unsupported
        }
        if leafSubject.hasPrefix("Apple Development:") {
            return .appleDevelopment(teamIdentifier: teamIdentifier)
        }
        if leafSubject.hasPrefix("Developer ID Application:") {
            return .developerIDApplication(teamIdentifier: teamIdentifier)
        }
        return .unsupported
    }
}
