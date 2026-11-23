import CoreAudio
import Foundation

/// `Spatial --transparency` (run as the app so it has audio-capture
/// permission): plays known noise through the system player while a muted
/// tap records this app's own output, then lines the two up and reports how
/// far they differ. Bit-identical playback reports "identical".
func runTransparencyTest() -> Bool {
    let rate = 48_000.0
    let seconds = args.contains("--tone") ? 12.0 : 3.0
    let total = Int(seconds * rate)
    var rng = SystemRandomNumberGenerator()
    // Unmuted runs use a whisper so nobody is startled.
    let unmuted = args.contains("--unmuted")
    let amp: Float = unmuted ? 0.003 : 0.25
    // `--tone`: a steady 997 Hz sine, for measuring speed wobble by phase.
    let tone = args.contains("--tone")
    let srcL = (0..<total).map { i in tone ? amp * sin(2 * .pi * 997 * Float(i) / Float(rate)) : Float.random(in: -amp...amp, using: &rng) }
    let srcR = tone ? srcL : (0..<total).map { _ in Float.random(in: -amp...amp, using: &rng) }

    let player = SystemPlayer()
    let direct = args.contains("--direct") ? DirectOutput(ring: player.ring) : nil
    let monitor = OutputMonitor(mute: !unmuted, recordFrames: Int((seconds + 2) * rate))
    do {
        if let direct { try direct.start() } else { try player.start(sampleRate: rate, outputLatency: CA.defaultOutput().map(CA.latency(of:)) ?? 0) }
        // Make this process an audio client before tapping it.
        let silence = [Float](repeating: 0, count: 480)
        for _ in 0..<20 { player.ring.write(left: silence, right: silence, frames: 480); Thread.sleep(forTimeInterval: 0.01) }
        try monitor.start()
    } catch {
        print("FAIL  transparency setup: \(error)")
        return false
    }

    // Feed at real-time pace.
    let t0 = Date()
    var fed = 0
    while fed < total {
        Thread.sleep(forTimeInterval: 0.005)
        let due = min(total, Int(Date().timeIntervalSince(t0) * rate))
        while fed < due {
            let n = min(480, due - fed)
            srcL.withUnsafeBufferPointer { l in srcR.withUnsafeBufferPointer { r in
                player.ring.write(left: l.baseAddress! + fed, right: r.baseAddress! + fed, frames: n)
            } }
            fed += n
            // `--simulate`: a configuration change at 4 s, an automatic
            // flush at 8 s, to check both are handled without a click.
            if args.contains("--simulate") {
                if fed >= Int(4 * rate), fed - n < Int(4 * rate) { player.simulateConfigurationChange() }
                if fed >= Int(8 * rate), fed - n < Int(8 * rate) { player.simulateAutomaticFlush() }
                // `--fail`: the renderer "fails" at 10 s; it must be replaced
                // and the sound come back.
                if args.contains("--fail"), fed >= Int(10 * rate), fed - n < Int(10 * rate) { player.simulateFailure() }
            }
        }
    }
    print(String(format: "player: queued %.0f ms, failed: %@, live peak %.3f", player.queuedAhead * 1000,
                 player.failed.map { "\($0)" } ?? "no", monitor.takePeak()))
    Thread.sleep(forTimeInterval: 1.0)
    monitor.stop()
    player.stop()
    direct?.stop()

    let got = monitor.recordedFrames
    let rec = monitor.recording
    // Where is there sound in the recording? (per 0.25 s)
    var profile: [String] = []
    for b in stride(from: 0, to: got, by: 12_000) {
        var p: Float = 0
        for i in b..<min(got, b + 12_000) { p = max(p, abs(rec[i * 2])) }
        profile.append(String(format: "%.4f", p))
    }
    print("recorded \(got) frames, peak per 0.25 s: \(profile.joined(separator: " "))")
    #if DEBUG
    if let dir = ProcessInfo.processInfo.environment["DUMP"] ?? (args.firstIndex(of: "--dump").map { args[$0 + 1] }) {
        let src = (0..<total).flatMap { [srcL[$0], srcR[$0]] }
        try? src.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: dir + "/source.f32"))
        try? Data(bytes: rec, count: got * 8).write(to: URL(fileURLWithPath: dir + "/recorded.f32"))
    }
    #endif
    // Find where the source starts in the recording with a 4096-sample template.
    let template = 4096, offset = 24_000
    var bestLag = -1
    var best: Float = 0
    if got > template + 1 {
        for lag in 0..<(got - template) {
            var dot: Float = 0
            for i in 0..<template { dot += rec[(lag + i) * 2] * srcL[offset + i] }
            if dot > best { best = dot; bestLag = lag }
        }
    }
    guard bestLag >= 0 else {
        print("FAIL  nothing recognisable came out (recorded \(got) frames)")
        return false
    }
    let start = bestLag - offset   // recording frame where source frame 0 sits
    var sig: Double = 0, err: Double = 0, maxDiff: Float = 0, n = 0, same = 0
    var dotGain: Double = 0
    for i in offset..<(total - 2_000) {
        let j = start + i
        guard j >= 0, j < got else { continue }
        dotGain += Double(rec[j * 2] * srcL[i])
        sig += Double(srcL[i] * srcL[i])
    }
    let gain = sig > 0 ? dotGain / sig : 1
    sig = 0
    for i in offset..<(total - 2_000) {
        let j = start + i
        guard j >= 0, j < got else { continue }
        for (a, b) in [(rec[j * 2], srcL[i]), (rec[j * 2 + 1], srcR[i])] {
            let d = a - b
            sig += Double(b * b); err += Double(d * d)
            maxDiff = max(maxDiff, abs(d))
            if a == b { same += 1 }
            n += 1
        }
    }
    let snr = err > 0 ? 10 * log10(sig / err) : .infinity
    let identical = Double(same) / Double(max(n, 1))
    print(String(format: "gain %.4f (%.2f dB), residual %@, max sample difference %.2e, bit-identical samples %.1f%%",
                 gain, 20 * log10(max(gain, 1e-9)),
                 snr.isInfinite ? "none" : String(format: "%.1f dB below the music", snr),
                 maxDiff, identical * 100))
    let pass = snr > 90
    print(pass ? "PASS  the player is transparent" : "FAIL  the player changes the sound")
    return pass
}

/// For comparison: plays the ring straight to the default output with a
/// plain HAL IOProc, no media player in between.
final class DirectOutput {
    let ring: Ring
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let staging = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    init(ring: Ring) { self.ring = ring }
    func start() throws {
        guard let out = CA.defaultOutput() else { throw AudioError("no output") }
        device = out
        let ring = self.ring, staging = self.staging
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, out, nil) { _, _, _, output, _ in
            let outs = UnsafeMutableAudioBufferListPointer(output)
            guard outs.count > 0, let d = outs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = Int(outs[0].mNumberChannels)
            let frames = min(8192, Int(outs[0].mDataByteSize) / (4 * max(1, ch)))
            let n = ring.read(into: staging, frames: frames)
            for i in 0..<frames {
                for c in 0..<ch { d[i * ch + c] = i < n && c < 2 ? staging[i * 2 + c] : 0 }
            }
        }, "direct proc")
        try check(AudioDeviceStart(out, procID), "direct start")
    }
    func stop() {
        if let procID { AudioDeviceStop(device, procID); AudioDeviceDestroyIOProcID(device, procID) }
        procID = nil
    }
}
