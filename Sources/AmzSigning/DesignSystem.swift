import SwiftUI
import AppKit

/// Semantic colors keep the entire interface coherent in both macOS appearances.
enum SigningStyle {
    static let canvas = adaptive(0xFFFFFF, 0x131416)
    static let surface = adaptive(0xFFFFFF, 0x1C1E21)
    static let soft = adaptive(0xF8FAFD, 0x20242B)
    static let ink = adaptive(0x202124, 0xE8EAED)
    static let secondary = adaptive(0x5F6368, 0xB3B8C0)
    static let line = adaptive(0xDADCE0, 0x3C4043)
    static let blue = adaptive(BrandArtwork.accentRGB, 0xA8C7FA)
    static let selection = adaptive(0xD3E9FC, 0x254367)
    static let blueSoft = adaptive(BrandArtwork.tintRGB, 0x24364D)
    static let green = adaptive(0x188038, 0x81C995)
    static let amber = adaptive(0x9C5700, 0xFDD663)
    static let action = Color(nsColor: BrandArtwork.color(BrandArtwork.primaryRGB))
    static let mark = BrandArtwork.image(size: 128)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            BrandArtwork.color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

struct SigningButtonStyle: ButtonStyle {
    enum Kind { case primary, text }
    var kind: Kind = .primary
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, kind == .text ? 4 : compact ? 13 : 20)
            .frame(height: compact ? 32 : 42)
            .foregroundStyle(kind == .primary ? .white : SigningStyle.blue)
            .background(kind == .primary ? SigningStyle.action : .clear, in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? configuration.isPressed ? 0.72 : 1 : 0.38)
    }
}

extension View {
    func signingCard(padding: CGFloat = 22) -> some View {
        self.padding(padding)
            .background(SigningStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(SigningStyle.line, lineWidth: 1))
    }
}

struct StatusLabel: View {
    let title: String
    var color: Color = SigningStyle.green
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11, weight: .medium))
        }.foregroundStyle(color)
    }
}

struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 28, weight: .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
