import SwiftUI

struct PermissionStatusRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let status: PermissionState
    let actionLabel: String?
    let action: (() -> Void)?
    let compact: Bool

    init(icon: String, title: String, subtitle: String? = nil,
         status: PermissionState, actionLabel: String? = nil,
         action: (() -> Void)? = nil, compact: Bool = true) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.actionLabel = actionLabel
        self.action = action
        self.compact = compact
    }

    var body: some View {
        if compact {
            compactRow
        } else {
            cardRow
        }
    }

    // MARK: - Compact (Settings)

    private var compactRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                statusBadge
                if status != .granted, let label = actionLabel, let act = action {
                    Button(label) { act() }
                        .font(AppTheme.Fonts.caption)
                        .buttonStyle(.bordered)
                }
            }
        } label: {
            labelContent
        }
    }

    // MARK: - Card (Onboarding)

    private var cardRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(AppTheme.Colors.brandLight)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.brandPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Fonts.listTitle)
                    .foregroundStyle(AppTheme.Colors.primaryText)
                if let sub = subtitle {
                    Text(sub)
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }

            Spacer()

            statusBadge

            if status != .granted, let label = actionLabel, let act = action {
                Button(label) { act() }
                    .font(AppTheme.Fonts.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                .fill(AppTheme.Colors.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cornerRadius)
                .stroke(AppTheme.Colors.subtleBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Shared

    private var labelContent: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Colors.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let sub = subtitle {
                    Text(sub)
                        .font(AppTheme.Fonts.caption)
                        .foregroundStyle(AppTheme.Colors.tertiaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.Colors.accentGreen)
                .font(compact ? AppTheme.Fonts.caption : AppTheme.Fonts.listTitle)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .foregroundStyle(AppTheme.Colors.accentRed)
                .font(compact ? AppTheme.Fonts.caption : AppTheme.Fonts.listTitle)
        case .unknown:
            Label("Not yet prompted", systemImage: "minus.circle")
                .foregroundStyle(AppTheme.Colors.tertiaryText)
                .font(compact ? AppTheme.Fonts.caption : AppTheme.Fonts.listTitle)
        case .notApplicable:
            Label("N/A", systemImage: "minus.circle.fill")
                .foregroundStyle(AppTheme.Colors.tertiaryText)
                .font(compact ? AppTheme.Fonts.caption : AppTheme.Fonts.listTitle)
        }
    }
}