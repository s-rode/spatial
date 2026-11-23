import AppKit

// Spatial              menu bar app: Spotify through Apple's spatial renderer
// Spatial --smoke      headless self-test of both engines, prints PASS or FAIL
// Spatial --probe      lists audio processes and the output device; no tap, no permission
// Spatial --transparency  (via `open --args`) null test of the system player, muted
// Spatial --log        (with the app) prints state and input level to stderr once a second

let args = CommandLine.arguments

if args.contains("--smoke") {
    exit(runSmokeTest() ? 0 : 1)
}

if args.contains("--probe") {
    runProbe()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
