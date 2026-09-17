//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift
import os

actor HighlightTaskManager: ObservableObject {
  /// Shared Highlight instance to avoid creating multiple JSContext/HLJS instances.
  /// Each Highlight() creates its own JSContext and evaluates highlight.min.js (~600KB).
  /// When multiple CodeBlockViews render concurrently, N separate JSContexts cause
  /// JavaScriptCore OOM crashes (COPILOT-IOS-3F9C, 3F7Z, 3FSQ).
  private static let sharedHighlight = Highlight()

  /// A highlight result is a pure function of (code, language, colors), and
  /// tokenizing a 20-line block costs ~17 ms with auto-detection. A virtualized
  /// transcript re-runs `CodeBlockView.onAppear` every time a block is recycled
  /// back on screen, so without a cache that cost is paid again on every pass.
  ///
  /// The cache is static because each `CodeBlockView` owns its own task manager
  /// in a `@StateObject`, and that state is destroyed when the view is recycled.
  public struct CacheKey: Hashable, Sendable {
    public let code: String
    public let language: String
    public let colors: HighlightColors

    public init(code: String, language: String, colors: HighlightColors) {
      self.code = code
      self.language = language
      self.colors = colors
    }
  }

  @WithLock
  private static var cache: [CacheKey: AttributedString] = [:]
  @WithLock
  private static var cacheOrder: [CacheKey] = []

  /// Bounded so a long session cannot pin every code block ever displayed.
  private static let cacheLimit = 512

  private static let signposter = OSSignposter(subsystem: "ai.aureways.client", category: "Highlight")

  public static func cached(_ key: CacheKey) -> AttributedString? {
    $cache.read(closure: { $0[key] })
  }

  public static func store(_ value: AttributedString, for key: CacheKey) {
    let isNew = $cache.mutate { entries -> Bool in
      entries.updateValue(value, forKey: key) == nil
    }
    guard isNew else { return }
    let evicted = $cacheOrder.mutate { order -> CacheKey? in
      order.append(key)
      return order.count > cacheLimit ? order.removeFirst() : nil
    }
    if let evicted {
      $cache.mutate { $0.removeValue(forKey: evicted) }
    }
  }

  public static func clearCache() {
    $cache.mutate { $0.removeAll() }
    $cacheOrder.mutate { $0.removeAll() }
  }

  private var latestCode: String?
  private var latestColors: HighlightColors?
  private var latestLanguage: String = ""
  private var queueWaitSignpostState: OSSignpostIntervalState?
  private var isProcessing = false

  func enqueueCode(
    _ code: String,
    language: String = "",
    colors: HighlightColors,
    completion: @escaping (AttributedString) -> Void
  ) {
    // A cache hit skips the JS round trip entirely, which is what makes
    // scrolling back over already-seen code blocks free.
    let key = CacheKey(code: code, language: language, colors: colors)
    if let hit = Self.cached(key) {
      Task { @MainActor in completion(hit) }
      return
    }

    latestCode = code
    latestColors = colors
    latestLanguage = language

    if queueWaitSignpostState == nil {
      let waitID = Self.signposter.makeSignpostID()
      queueWaitSignpostState = Self.signposter.beginInterval("HighlightQueueWait", id: waitID)
    }

    if !isProcessing {
      Task {
        await processQueue(completion: completion)
      }
    }
  }

  private func processQueue(completion: @escaping (AttributedString) -> Void) async {
    guard !isProcessing else { return }

    isProcessing = true

    while let codeToProcess = latestCode, let colors = latestColors {
      let language = latestLanguage
      latestCode = nil

      if let state = queueWaitSignpostState {
        Self.signposter.endInterval("HighlightQueueWait", state)
        queueWaitSignpostState = nil
      }

      let execID = Self.signposter.makeSignpostID()
      let execState = Self.signposter.beginInterval("HighlightExecution", id: execID)

      // An explicit language is ~5x cheaper than auto-detection across every
      // bundled language, and the fence usually carries one.
      let result: AttributedString?
      if !language.isEmpty,
         let highlighted = try? await Self.sharedHighlight.attributedText(
           codeToProcess, language: language, colors: colors
         ) {
        result = highlighted
      } else {
        // An unrecognized alias throws; fall back to auto-detection rather than showing plain text.
        result = try? await Self.sharedHighlight.attributedText(codeToProcess, colors: colors)
      }

      Self.signposter.endInterval("HighlightExecution", execState)

      if let result {
        Self.store(result, for: CacheKey(code: codeToProcess, language: language, colors: colors))
        await MainActor.run {
          completion(result)
        }
      }
    }

    isProcessing = false
  }
}
