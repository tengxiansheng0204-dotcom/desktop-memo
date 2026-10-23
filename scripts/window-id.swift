import Foundation
import CoreGraphics

let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.filter { entry in
    guard let owner = entry[kCGWindowOwnerPID as String] as? Int,
          owner == pid,
          let bounds = entry[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double else { return false }
    return width >= 350 && height >= 400
}
FileHandle.standardError.write(Data("Screen capture permission: \(CGPreflightScreenCaptureAccess())\nMatching windows: \(candidates)\n".utf8))
guard let window = candidates.first,
      let number = window[kCGWindowNumber as String] as? Int else { exit(1) }
print(number)
