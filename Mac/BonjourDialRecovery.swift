import Foundation

/// One quick fresh resolution per service appearance; later failures retain normal backoff.
struct BonjourDialRecovery {
  private var firstServiceAttempt = true

  mutating func nextAttempt(isService: Bool) -> (timeout: TimeInterval, retry: TimeInterval) {
    guard isService, firstServiceAttempt else { return (5, 1) }
    firstServiceAttempt = false
    return (0.75, 0)
  }
}
