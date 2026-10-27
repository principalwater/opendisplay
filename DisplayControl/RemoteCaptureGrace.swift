import Foundation

/// A replacement capture may disappear briefly; explicit session end never gets a grace period.
struct RemoteCaptureGrace {
  private var wasActive = false
  private(set) var deadline: TimeInterval?

  mutating func retainRemote(sessionRequested: Bool, captureActive: Bool,
    now: TimeInterval) -> Bool {
    guard sessionRequested else {
      wasActive = false
      deadline = nil
      return false
    }
    if captureActive {
      wasActive = true
      deadline = nil
      return true
    }
    guard wasActive else { return false }
    if deadline == nil { deadline = now + 5 }
    return now < (deadline ?? now)
  }
}
