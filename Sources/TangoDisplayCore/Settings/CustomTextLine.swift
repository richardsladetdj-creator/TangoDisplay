import Foundation

/// A user-defined free-text display line with metadata placeholders (e.g.
/// `{Artist} {Year} ({Genre}) {Title} ({Singer})`). Stored per-profile on
/// `AppearanceProfile.customTextLines` and referenced from the order arrays via
/// `OrderEntry.custom(id)`.
public struct CustomTextLine: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String          // template with {Artist}, {Title}, …
    public var fontName: String      // "System" or family name
    public var fontSize: Double
    public var fontBold: Bool
    public var fontItalic: Bool
    public var colorHex: String      // "#RRGGBB"
    public var showInDance: Bool     // visibility in dance-track context
    public var showInCortina: Bool   // visibility in cortina "coming up" context

    enum CodingKeys: String, CodingKey {
        case id, text, fontName, fontSize, fontBold, fontItalic, colorHex, showInDance, showInCortina
    }

    public init(id: UUID = UUID(), text: String = "",
                fontName: String = "System", fontSize: Double = 48,
                fontBold: Bool = false, fontItalic: Bool = false,
                colorHex: String = "#FFFFFF",
                showInDance: Bool = true, showInCortina: Bool = true) {
        self.id = id
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontBold = fontBold
        self.fontItalic = fontItalic
        self.colorHex = colorHex
        self.showInDance = showInDance
        self.showInCortina = showInCortina
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,   forKey: .id)
        text          = try c.decode(String.self, forKey: .text)
        fontName      = try c.decodeIfPresent(String.self, forKey: .fontName)      ?? "System"
        fontSize      = try c.decodeIfPresent(Double.self, forKey: .fontSize)      ?? 48
        fontBold      = try c.decodeIfPresent(Bool.self,   forKey: .fontBold)      ?? false
        fontItalic    = try c.decodeIfPresent(Bool.self,   forKey: .fontItalic)    ?? false
        colorHex      = try c.decodeIfPresent(String.self, forKey: .colorHex)      ?? "#FFFFFF"
        showInDance   = try c.decodeIfPresent(Bool.self,   forKey: .showInDance)   ?? true
        showInCortina = try c.decodeIfPresent(Bool.self,   forKey: .showInCortina) ?? true
    }
}
