import OmarchyInstallerUXCore
import SwiftUI

// MARK: - Building blocks

struct Panel<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      content
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 13)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: OmarchyTheme.cardRadius)
        .fill(OmarchyTheme.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: OmarchyTheme.cardRadius)
        .strokeBorder(OmarchyTheme.separator, lineWidth: 1)
    )
  }
}

struct FactGrid: View {
  let rows: [PlanFactRow]
  var labelWidth: CGFloat = 118

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(rows) { row in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(row.label)
            .font(OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.secondaryText)
            .frame(width: labelWidth, alignment: .leading)
          Text(row.value)
            .font(row.isMonospaced ? OmarchyTheme.monospaceSmall : OmarchyTheme.body)
            .foregroundStyle(OmarchyTheme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
      }
    }
  }
}

struct StatusBadge: View {
  enum Kind { case ok, blocked }

  let text: String
  let kind: Kind

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(
        kind == .ok ? OmarchyTheme.accentText : Color.white
      )
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .background(
        Capsule().fill(
          kind == .ok ? OmarchyTheme.accent : OmarchyTheme.danger
        )
      )
  }
}

struct DiskBar: View {
  let macOSBytes: UInt64
  let omarchyBytes: UInt64
  var unallocatedBytes: UInt64 = 0
  /// When set, the divider between the segments is draggable and reports the
  /// Omarchy share of the disk (0...1) as it moves.
  var onAdjustOmarchyFraction: ((Double) -> Void)?
  /// Called once when the drag ends, with the final Omarchy share.
  var onCommitOmarchyFraction: ((Double) -> Void)?
  /// While set, the divider is drawn but drags are ignored (a re-plan is in
  /// flight). Keeping the handle on screen avoids it flashing off and on.
  var isFrozen = false

  var body: some View {
    GeometryReader { geometry in
      let total = max(1, Double(macOSBytes + omarchyBytes + unallocatedBytes))
      let width = geometry.size.width
      let omarchyWidth = width * Double(omarchyBytes) / total
      ZStack(alignment: .leading) {
        HStack(spacing: 0) {
          segment(
            name: unallocatedBytes > 0 ? "macOS and free space" : "macOS",
            bytes: macOSBytes + unallocatedBytes,
            width: width - omarchyWidth,
            background: OmarchyTheme.track,
            foreground: OmarchyTheme.secondaryText
          )
          segment(
            name: "Omarchy",
            bytes: omarchyBytes,
            width: omarchyWidth,
            background: OmarchyTheme.accent,
            foreground: OmarchyTheme.accentText
          )
        }
        if onAdjustOmarchyFraction != nil {
          RoundedRectangle(cornerRadius: 3)
            .fill(OmarchyTheme.handle)
            .frame(width: 6, height: 18)
            .overlay(
              RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 1.5)
            .offset(x: min(max(4, width - omarchyWidth - 3), width - 10))
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard !isFrozen else { return }
            let x = min(max(0, value.location.x), width)
            onAdjustOmarchyFraction?(1 - x / max(1, width))
          }
          .onEnded { value in
            guard !isFrozen else { return }
            let x = min(max(0, value.location.x), width)
            onCommitOmarchyFraction?(1 - x / max(1, width))
          },
        including: onAdjustOmarchyFraction == nil ? .none : .all
      )
    }
    .frame(height: 24)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Disk space")
    .accessibilityValue(
      "macOS \(PlainLanguage.bytes(macOSBytes)), Omarchy \(PlainLanguage.bytes(omarchyBytes)), unallocated \(PlainLanguage.bytes(unallocatedBytes))"
    )
    .accessibilityAdjustableAction { direction in
      guard !isFrozen else { return }
      let total = max(1, Double(macOSBytes + omarchyBytes + unallocatedBytes))
      let change: Double
      switch direction {
      case .increment: change = 1_000_000_000
      case .decrement: change = -1_000_000_000
      @unknown default: return
      }
      onCommitOmarchyFraction?(min(1, max(0, (Double(omarchyBytes) + change) / total)))
    }
  }

  private func segment(
    name: String,
    bytes: UInt64,
    width: CGFloat,
    background: Color,
    foreground: Color
  ) -> some View {
    ZStack {
      background
      // Center each live capacity in the full area on its side of the handle.
      Text(PlainLanguage.bytes(bytes))
        .accessibilityLabel(name + " " + PlainLanguage.bytes(bytes))
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(foreground)
        .lineLimit(1)
        .padding(.horizontal, 4)
    }
    .frame(width: max(0, width))
  }
}

struct ProgressTrack: View {
  let fraction: Double?
  var height: CGFloat = 6

  @State private var sweep = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(OmarchyTheme.track)
        if let fraction {
          Capsule()
            .fill(OmarchyTheme.accent)
            .frame(width: geometry.size.width * min(1, max(0, fraction)))
            .animation(.linear(duration: 0.18), value: fraction)
        } else {
          Capsule()
            .fill(OmarchyTheme.accent.opacity(0.75))
            .frame(width: geometry.size.width * 0.32)
            .offset(x: sweep ? geometry.size.width * 0.68 : 0)
            .animation(
              .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
              value: sweep
            )
            .onAppear { sweep = !reduceMotion }
        }
      }
    }
    .frame(height: height)
  }
}

struct RecoveryStepRow: View {
  let step: RecoveryStep

  var body: some View {
    HStack(alignment: .center, spacing: 13) {
      Text("\(step.number)")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(OmarchyTheme.accentText)
        .frame(width: 24, height: 24)
        .background(Circle().fill(OmarchyTheme.accent))
      Text(step.title)
        .font(.system(size: 13, weight: .semibold))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: OmarchyTheme.cardRadius)
        .fill(OmarchyTheme.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: OmarchyTheme.cardRadius)
        .strokeBorder(OmarchyTheme.separator, lineWidth: 1)
    )
  }
}

/// Raw error text, kept verbatim so nothing is lost behind plain language.
struct TechnicalDetailText: View {
  let text: String

  var body: some View {
    Text(text)
      .font(OmarchyTheme.monospaceSmall)
      .foregroundStyle(OmarchyTheme.secondaryText)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8).fill(OmarchyTheme.window)
      )
  }
}

/// Rectangular action buttons with rounded corners — the system's large
/// bordered styles render as capsules, which the approved look rejects.
struct OmarchyPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .medium))
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(OmarchyTheme.accentText)
      .padding(.horizontal, 21)
      .frame(height: 42)
      .background(
        RoundedRectangle(cornerRadius: 9)
          .fill(OmarchyTheme.accent)
      )
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
  }
}

struct OmarchySecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15))
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(OmarchyTheme.text)
      .padding(.horizontal, 21)
      .frame(height: 42)
      .background(
        RoundedRectangle(cornerRadius: 9)
          .fill(OmarchyTheme.card)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(OmarchyTheme.separator, lineWidth: 1)
      )
      .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
  }
}

extension View {
  func omarchyPrimaryButton() -> some View {
    buttonStyle(OmarchyPrimaryButtonStyle())
  }

  func omarchySecondaryButton() -> some View {
    buttonStyle(OmarchySecondaryButtonStyle())
  }
}
