import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        // English UI is intentional; transcript language is independent.
        let resources: Bundle
        if let url = Bundle.main.url(forResource: "noato_quill", withExtension: "bundle"), let embedded = Bundle(url: url) { resources = embedded }
        else { resources = Bundle.module }
        let bundle = resources.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:)) ?? resources
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: "en_US"), arguments: args)
    }
}
