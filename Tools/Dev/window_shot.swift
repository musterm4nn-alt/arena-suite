// Captures only the frontmost window of one app (never the whole screen).
// Usage: swift Tools/Dev/window_shot.swift <owner name> <output.png>
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: window_shot <owner> <out.png>"); exit(2) }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
guard let window = windows.first(where: { ($0[kCGWindowOwnerName as String] as? String) == args[1] && ($0[kCGWindowLayer as String] as? Int) == 0 }),
    let number = window[kCGWindowNumber as String] as? Int
else { print("window not found"); exit(1) }
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l\(number)", args[2]]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
