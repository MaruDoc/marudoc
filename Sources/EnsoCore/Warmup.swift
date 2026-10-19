import Foundation
import EnsoDoc

/// Lets the app warm up the docx writer without importing EnsoOffice directly.
public enum DocumentWarmup {
    public static func writeDocx(_ model: DocModel, to url: URL) throws { try Formats.writeDocx(model, to: url) }
}
