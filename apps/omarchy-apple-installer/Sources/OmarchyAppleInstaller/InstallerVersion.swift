import Foundation

/// A three-component installer version, ordered numerically.
///
/// The installer's own version is independent of the Omarchy release it
/// installs: the app ships on its own line and a signed catalog states which
/// installer versions it still accepts.
public struct InstallerVersion: Comparable, Hashable, Sendable,
  CustomStringConvertible
{
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// Parses exactly `major.minor.patch`. Anything else is rejected so a
  /// malformed catalog value can never compare as "new enough".
  public init?(_ string: String) {
    let components = string.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else {
      return nil
    }
    var numbers = [Int]()
    for component in components {
      guard !component.isEmpty,
        component.allSatisfy(\.isASCII),
        component.allSatisfy(\.isNumber),
        component == "0" || !component.hasPrefix("0"),
        let number = Int(component)
      else {
        return nil
      }
      numbers.append(number)
    }
    self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
  }

  public var description: String {
    "\(major).\(minor).\(patch)"
  }

  public static func < (lhs: InstallerVersion, rhs: InstallerVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  /// The running app's version, or `nil` when there is no bundle to read it
  /// from — a bare SwiftPM build. Callers treat `nil` as "unknown" and skip
  /// the compatibility check rather than refusing to run.
  public static func current(bundle: Bundle = .main) -> InstallerVersion? {
    guard
      let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
    else {
      return nil
    }
    return InstallerVersion(value)
  }
}
