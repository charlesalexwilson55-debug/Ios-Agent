import Foundation

@main struct SettingsTests {
    static func main() {
        precondition(SearchKeyKind.detect("tvly-dev-abcdefghijklmnopqrstuvwxyz") == .tavily)
        precondition(SearchKeyKind.detect(" 12345678-1234-1234-1234-123456789abc\n") == .exa)
        precondition(SearchKeyKind.detect("exa-abcdefghijklmnopqrstuvwxyz") == .exa)
        precondition(SearchKeyKind.detect("tvly-") == nil)
        precondition(SearchKeyKind.detect("a short invalid key") == nil)
        print("Automatic provider key identification passed")
    }
}
