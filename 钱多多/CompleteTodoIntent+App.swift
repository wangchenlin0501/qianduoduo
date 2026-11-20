import AppIntents

// This routing capability is unavailable in extensions. It keeps pre-iOS 27
// widget actions in the app process, where the original CloudKit stores live.
@available(iOSApplicationExtension, unavailable)
extension CompleteTodoIntent: ForegroundContinuableIntent {}
