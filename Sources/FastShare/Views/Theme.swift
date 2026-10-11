import SwiftUI

/// The app's white palette (Tailwind slate/blue values), independent of the system appearance.
enum Theme {
    static let accent = Color(red: 0.145, green: 0.388, blue: 0.922) // #2563EB
    static let accentSoft = Color(red: 0.937, green: 0.957, blue: 1.0) // #EFF6FF
    static let text = Color(red: 0.059, green: 0.090, blue: 0.165) // #0F172A
    static let secondaryText = Color(red: 0.392, green: 0.455, blue: 0.545) // #64748B
    static let tertiaryText = Color(red: 0.580, green: 0.639, blue: 0.722) // #94A3B8
    static let border = Color(red: 0.886, green: 0.910, blue: 0.941) // #E2E8F0
    static let sidebar = Color(red: 0.980, green: 0.984, blue: 0.988) // #FAFBFC
    static let fill = Color(red: 0.945, green: 0.961, blue: 0.976) // #F1F5F9
    static let hover = Color(red: 0.937, green: 0.945, blue: 0.957) // #EFF1F4
    static let success = Color(red: 0.086, green: 0.639, blue: 0.290) // #16A34A
    static let warning = Color(red: 0.851, green: 0.467, blue: 0.024) // #D97706
    static let danger = Color(red: 0.863, green: 0.149, blue: 0.149) // #DC2626
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var isDestructive = false
    var isCompact = false
    /// Background at rest; use white on top of `Theme.fill` surfaces.
    var background = Theme.fill
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isCompact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(isDestructive ? Theme.danger : Theme.text)
            .padding(.horizontal, isCompact ? 9 : 12)
            .padding(.vertical, isCompact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Theme.border : background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(background == .white ? Theme.border : .clear)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
