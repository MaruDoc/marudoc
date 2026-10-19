import Foundation

/// Japanese is the source language. Other locales get English.
public func L(_ ja: String) -> String {
    if Localization.isJapanese { return ja }
    return Localization.english(ja) ?? ja
}

public enum Localization {
    public static let isJapanese: Bool = {
        let lang = Locale.preferredLanguages.first ?? "en"
        return lang.hasPrefix("ja")
    }()

    static let en: [String: String] = [
        "Word に変換": "Convert to Word", "Office に変換": "Convert to Office", "Office": "Office", "Word (.docx)": "Word (.docx)", "Excel (.xlsx)": "Excel (.xlsx)",
        "PowerPoint (.pptx)": "PowerPoint (.pptx)", "画像に変換": "Convert to Image", "画像": "Image",
        "テキストに変換": "Convert to Text", "テキスト": "Text", "編集": "Edit", "編集…": "Edit…", "トリミング": "Crop", "トリミング…": "Crop…",
        "ページ": "Pages", "ページを整理…": "Organize Pages…", "整理": "Organize", "右に回転": "Rotate Right",
        "右回転": "Right", "左に回転": "Rotate Left", "左回転": "Left", "1ページずつ分割": "Split into Pages",
        "分割": "Split", "画像を取り出す": "Extract Images", "画像抽出": "Images", "圧縮": "Compress",
        "軽く圧縮 (画質優先)": "Compress Lightly (Quality)", "軽め": "Light", "標準の圧縮": "Compress",
        "標準": "Standard", "強く圧縮 (サイズ優先)": "Compress Strongly (Size)", "強め": "Strong",
        "その他": "More", "文字認識して検索可能に": "Make Searchable (OCR)", "文字認識": "OCR",
        "パスワード…": "Password…", "パスワード": "Password", "ページ番号を付ける": "Add Page Numbers",
        "ページ番号": "Numbers", "透かしを入れる…": "Add Watermark…", "透かし": "Watermark",
        "テキストをコピー": "Copy Text", "コピー": "Copy", "変換": "Convert", "サイズ変更": "Resize",
        "サイズ": "Size", "50% に縮小": "Shrink to 50%", "25% に縮小": "Shrink to 25%",
        "長辺 2048px": "Long Edge 2048px", "長辺 1080px": "Long Edge 1080px", "サイズを指定…": "Custom Size…",
        "指定": "Custom", "回転": "Rotate", "左右反転": "Flip Horizontal", "上下反転": "Flip Vertical",
        "背景を削除": "Remove Background", "背景削除": "Background", "文字認識してテキストに": "Recognize Text (OCR)",
        "位置情報などを削除": "Remove Location & Metadata", "情報削除": "Metadata", 
        "PDF に変換": "Convert to PDF", "ほかの形式に変換": "Convert to Other Format", "形式": "Format",
        "テキスト (.txt)": "Plain Text (.txt)", "リッチテキスト (.rtf)": "Rich Text (.rtf)",
        "CSV に変換": "Convert to CSV", "Excel に変換": "Convert to Excel", "Markdown の表に変換": "Convert to Markdown Table",
        "HTML に変換": "Convert to HTML", "PDF に変換 (テキストと画像)": "Convert to PDF (Text & Images)",
        "Markdown に変換": "Convert to Markdown", "1つの PDF にまとめる": "Combine into One PDF", "まとめる": "Combine", "結合": "Combine",
        "まとめて Office に変換": "Convert All to Office", "まとめて画像に変換": "Convert All to Images",
        "まとめてテキストに変換": "Convert All to Text", "まとめて圧縮": "Compress All", "まとめて文字認識": "OCR All",
        "まとめて変換": "Convert All", "まとめてサイズ変更": "Resize All", "まとめて回転": "Rotate All",
        "まとめて背景を削除": "Remove Backgrounds", "まとめて位置情報などを削除": "Remove Metadata from All",
        "まとめて PDF に変換": "Convert All to PDF", "まとめて Markdown に変換": "Convert All to Markdown",
        "PowerPoint に変換": "Convert to PowerPoint", "PNG に変換": "Convert to PNG", "JPEG に変換": "Convert to JPEG",
        "HEIC に変換": "Convert to HEIC", "TIFF に変換": "Convert to TIFF", "RTF に変換": "Convert to RTF",
        "ページを分割": "Split Pages", "軽く圧縮": "Compress Lightly",
        "強く圧縮": "Compress Strongly", "パスワードを設定": "Set Password", "パスワードを解除": "Remove Password",
        "注釈を統合": "Flatten Annotations", "長辺 2048px に縮小": "Shrink to 2048px", "長辺 1080px に縮小": "Shrink to 1080px",
        "PDF にまとめる": "Combine into PDF", "ページを整理": "Organize Pages", "MaruDoc の設定…": "MaruDoc Settings…", "%d 項目": "%d items",
    ]

    /// Lets the app add its own strings to the same table.
    public static func register(_ table: [String: String]) {
        extra.merge(table) { _, new in new }
    }
    nonisolated(unsafe) static var extra: [String: String] = [:]

    public static func english(_ ja: String) -> String? { en[ja] ?? extra[ja] }
}
