import Foundation
import EnsoShared
import EnsoDoc
import EnsoOffice

/// User-facing wording for errors from any module (OfficeError's own messages are English and technical).
public enum ErrorText {
    public static func describe(_ error: Error) -> String {
        if let o = error as? OfficeError {
            switch o {
            case .encryptedOrLegacyOffice: return L("パスワード付き、または古い形式 (.doc / .xls / .ppt) の Office ファイルです")
            case .notAZip, .corruptZip, .malformedXML, .invalidDocument, .missingPart: return L("ファイルが壊れているか、対応していない形式です")
            case .unsupportedZipFeature: return L("このファイルの圧縮形式には対応していません")
            case .tooLarge: return L("ファイルが大きすぎます")
            case .invalidArgument, .io: return L("ファイルを読み書きできませんでした")
            }
        }
        if let l = error as? LocalizedError, let d = l.errorDescription { return d }
        return error.localizedDescription
    }
}
