import Foundation

public enum InstallerAllocationRecommendationError:
  Error, Equatable, Sendable
{
  case noEligibleCandidate
}

public struct InstallerAllocationRecommendation:
  Equatable, Sendable
{
  public static let balancedTargetBytes: UInt64 = 137_438_953_472

  public let candidate: ValidatedEngineCandidate
  public let minimumBytes: UInt64
  public let maximumBytes: UInt64
  public let requestedLengthBytes: UInt64

  public init(
    inventory: ValidatedEngineInventory,
    targetBytes: UInt64 = Self.balancedTargetBytes
  ) throws {
    let unit = PinnedAsahiPlanRequest.allocationUnitBytes
    let ranked = inventory.candidates.compactMap { candidate -> Ranked? in
      let maximum: UInt64
      if candidate.kind == "free" {
        maximum = candidate.lengthBytes
      } else if candidate.kind == "resize",
        candidate.lengthBytes > candidate.minimumContainerBytes
      {
        maximum = candidate.lengthBytes - candidate.minimumContainerBytes
      } else {
        return nil
      }

      let minimum = Self.alignUp(
        candidate.minimumInstallBytes,
        unit: unit
      )
      let alignedMaximum = maximum - (maximum % unit)
      guard minimum <= alignedMaximum else {
        return nil
      }
      return Ranked(
        candidate: candidate,
        minimum: minimum,
        maximum: alignedMaximum
      )
    }.sorted { left, right in
      if left.candidate.kind != right.candidate.kind {
        return left.candidate.kind == "free"
      }
      if left.maximum != right.maximum {
        return left.maximum > right.maximum
      }
      return left.candidate.sourceIdentifier
        < right.candidate.sourceIdentifier
    }

    guard let selected = ranked.first else {
      throw InstallerAllocationRecommendationError.noEligibleCandidate
    }
    let alignedTarget = targetBytes - (targetBytes % unit)
    candidate = selected.candidate
    minimumBytes = selected.minimum
    maximumBytes = selected.maximum
    requestedLengthBytes = min(
      selected.maximum,
      max(selected.minimum, alignedTarget)
    )
  }

  private static func alignUp(
    _ value: UInt64,
    unit: UInt64
  ) -> UInt64 {
    let remainder = value % unit
    guard remainder != 0 else {
      return value
    }
    let adjustment = unit - remainder
    let (result, overflow) = value.addingReportingOverflow(adjustment)
    return overflow ? UInt64.max : result
  }

  private struct Ranked {
    let candidate: ValidatedEngineCandidate
    let minimum: UInt64
    let maximum: UInt64
  }
}
