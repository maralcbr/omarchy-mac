#if os(macOS)
  import Foundation

  /// A draft cannot affect an approved disk plan. Only a valid explicit apply
  /// returns a requested allocation; cancelling restores the confirmed value.
  public struct DiskSizeInput: Equatable, Sendable {
    public private(set) var isEditing = false
    public var text = ""
    private var confirmedBytes: UInt64 = 0
    private var minimumBytes: UInt64 = 0
    private var maximumBytes: UInt64 = 0

    public init() {}

    public func display(_ bytes: UInt64) -> String {
      String(Int((Double(bytes) / 1_000_000_000).rounded()))
    }

    public mutating func begin(bytes: UInt64, minimum: UInt64, maximum: UInt64) {
      guard !isEditing else { return }
      confirmedBytes = bytes
      minimumBytes = minimum
      maximumBytes = maximum
      text = display(bytes)
      isEditing = true
    }

    public var requestedBytes: UInt64? {
      let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard candidate.range(of: #"^[0-9]{1,5}$"#, options: .regularExpression) != nil,
        let number = Decimal(string: candidate, locale: Locale(identifier: "en_US_POSIX"))
      else { return nil }
      // Merely confirming the rounded display must not alter the exact disk plan.
      if candidate == display(confirmedBytes) { return confirmedBytes }
      let bytes = number * 1_000_000_000
      guard bytes >= Decimal(minimumBytes), bytes <= Decimal(maximumBytes) else { return nil }
      return NSDecimalNumber(decimal: bytes).uint64Value
    }

    public var validationMessage: String? {
      guard isEditing, requestedBytes == nil else { return nil }
      return
        "Enter a whole number from \(Int(ceil(Double(minimumBytes) / 1_000_000_000))) to \(min(99999, Int(floor(Double(maximumBytes) / 1_000_000_000)))) GB."
    }

    public mutating func apply() -> UInt64? {
      guard isEditing, let bytes = requestedBytes else { return nil }
      confirmedBytes = bytes
      isEditing = false
      return bytes
    }

    public mutating func cancel() {
      text = display(confirmedBytes)
      isEditing = false
    }
  }
#endif
