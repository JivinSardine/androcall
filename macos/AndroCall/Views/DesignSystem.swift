import AndroCallCore
import SwiftUI

/// The androcall design system.
///
/// A small set of spacing, typography and colour tokens so that every screen
/// looks like it belongs to the same application. Light, dark and system
/// appearances are all supported.
public enum Design {

    // MARK: - Spacing

    public enum Spacing {
        public static let xSmall: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xLarge: CGFloat = 24
        public static let xxLarge: CGFloat = 32
    }

    public enum Radius {
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 10
        public static let large: CGFloat = 14
    }

    // MARK: - Colours

    public static let accent = Color(red: 0.20, green: 0.48, blue: 0.96)
    public static let success = Color(red: 0.16, green: 0.64, blue: 0.36)
    public static let warning = Color(red: 0.92, green: 0.66, blue: 0.16)
    public static let danger = Color(red: 0.86, green: 0.25, blue: 0.25)

    /// A colour that reads well in both appearances.
    public static func tinted(_ color: Color) -> Color {
        color.opacity(0.14)
    }
}

// MARK: - Reusable components

/// A labelled section header.
public struct SectionHeader: View {
    private let title: String
    private let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xSmall) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small status pill.
public struct StatusPill: View {
    private let text: String
    private let color: Color
    private let filled: Bool

    public init(_ text: String, color: Color = .secondary, filled: Bool = false) {
        self.text = text
        self.color = color
        self.filled = filled
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, Design.Spacing.small)
            .padding(.vertical, 3)
            .foregroundColor(filled ? .white : color)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                    .fill(filled ? color : Design.tinted(color))
            )
    }
}

/// A key/value row used across the settings and diagnostics screens.
public struct DetailRow: View {
    private let label: String
    private let value: String
    private let monospaced: Bool

    public init(_ label: String, _ value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.medium) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .body)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// An empty-state placeholder with an optional action.
public struct EmptyStateView: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Design.Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Design.Spacing.xxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A banner that reports an error with a dismiss action.
public struct ErrorBanner: View {
    private let message: String
    private let onDismiss: () -> Void

    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Design.danger)
            VStack(alignment: .leading, spacing: Design.Spacing.xSmall) {
                Text(message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(Design.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.medium, style: .continuous)
                .fill(Design.tinted(Design.danger))
        )
    }
}
