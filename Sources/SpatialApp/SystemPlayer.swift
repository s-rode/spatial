import AVFoundation
import CoreMedia
import Synchronization

/// Single-producer, single-consumer ring of interleaved stereo frames. The
/// audio thread writes, the player's queue reads; neither ever waits.
final class Ring {
    let capacity: Int
    private let data: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)   // total frames ever written
    private let consumed = Atomic<Int>(0)  // total frames ever read

    init(frames: Int = 1 << 16) {
        capacity = frames
        data = .allocate(capacity: frames * 2)
        data.initialize(repeating: 0, count: frames * 2)
    }

    deinit { data.deallocate() }

    var available: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .relaxed) }

    /// Frames ever written (to measure how fast the tap delivers).
    var totalWritten: Int { written.load(ordering: .acquiring) }

    /// Blocks dropped because the reader fell a whole ring behind.
    private(set) var overflows = 0

    /// Audio thread. Drops the block if the reader has fallen a whole ring behind.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let w = written.load(ordering: .relaxed)
        guard w + frames - consumed.load(ordering: .acquiring) <= capacity else { overflows += 1; return }
        for i in 0..<frames {
            let slot = ((w + i) % capacity) * 2
            data[slot] = left[i]
            data[slot + 1] = right[i]
        }
        written.store(w + frames, ordering: .releasing)
    }

    /// Reader. Copies up to `frames` interleaved frames into `out`.
    func read(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let r = consumed.load(ordering: .relaxed)
        let n = min(frames, written.load(ordering: .acquiring) - r)
        for i in 0..<n {
            let slot = ((r + i) % capacity) * 2
            out[i * 2] = data[slot]
            out[i * 2 + 1] = data[slot + 1]
        }
        consumed.store(r + n, ordering: .releasing)
        return n
    }

    /// Reader. Throws away what's waiting (to win back latency).
    func skipAll() {
        consumed.store(written.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// Plays Spotify's untouched stereo through AVSampleBufferAudioRenderer with
/// stereo spatialization allowed. That makes this app one macOS treats as
/// spatial-capable, so the AirPods menu in Control Center offers
/// Off / Fixed / Head Tracked and macOS does the rendering itself.
///
/// Switching that menu reconfigures the renderer mid-stream. The renderer
/// says so with two notifications (output configuration changed, flushed
/// automatically), and Apple's answer to both is to flush and re-enqueue from
/// the playhead. Ignoring them left stale or missing audio in the queue,
/// heard as static and the music lurching. So the player keeps the last
/// couple of seconds it sent (`history`) and re-sends exactly those samples
/// at the same timestamps.
final class SystemPlayer {
    let ring = Ring()
    /// Replaced when it fails: `.failed` is terminal (Apple: "recovery is not
    /// always possible"), and a flushed failed renderer just fails again.
    private var renderer = AVSampleBufferAudioRenderer()
    private var synchronizer = AVSampleBufferRenderSynchronizer()
    private var lastReplaced = Date.distantPast
    private let queue = DispatchQueue(label: "spatial.system-player", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var format: CMAudioFormatDescription?
    private var sampleRate: Double = 48_000
    private var timescale: CMTimeScale { CMTimeScale(sampleRate) }
    /// Timeline position, in frames, of the next frame to enqueue.
    private var nextFrame: Int64 = 0
    private var started = false
    private let chunk = 1024
    private let staging: UnsafeMutablePointer<Float>

    /// Every frame enqueued recently, at slot (timeline frame % historyFrames).
    /// 2.7 s at 48 kHz; the queue never runs more than 1.5 s ahead.
    private let historyFrames: Int64 = 1 << 17
    private let history: UnsafeMutablePointer<Float>
    /// Start frames of the buffers still waiting in the renderer, oldest first.
    private var bufferStarts: [Int64] = []
    /// While a partial flush is in flight nothing new is enqueued.
    private var reenqueuing = false
    /// Set while the output wakes up, either after the timeline starts (about
    /// 250 ms on AirPods) or after the renderer flushes itself. Meanwhile the
    /// clock stands still or lurches, so anything queued would play late by
    /// the whole wake-up, and trimming that later is an audible skip. Until
    /// the clock runs at real time, the player keeps silence queued and drops
    /// what the tap delivers. Then the music starts `targetLead` behind
    /// Spotify. That costs a fraction of a second after pressing play, but
    /// never a skip once it's playing.
    private var waking: Date?
    /// Recent (host, clock) readings while waking, to tell when the clock runs.
    private var clockSamples: [(host: Double, clock: Double)] = []
    /// Bumped whenever the timeline starts over, so a late flush completion
    /// for an older timeline is ignored.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    /// Every cut in the audio is smoothed: the next frames enqueued fade from
    /// `fadeFrom` (the audio that would have come next, or silence after a
    /// gap) into the new audio over a few ms. Hard cuts are clicks.
    private let fadeLength = 256          // crossfades: 5 ms
    private let fadeInLength = 960        // fade-ins after a gap: 20 ms
    private let fadeFrom: UnsafeMutablePointer<Float>
    private var fadeTotal = 0, fadeDone = 0
    private var skipCaptured = 0

    /// How far ahead of the playhead we aim to keep audio queued. Small
    /// enough not to notice, big enough to ride out a late timer.
    var lead = 0.04
    /// Extra headroom learned from underruns (starts at zero).
    private var cushion = 0.0
    /// Glitch counters for `--log`.
    private var underruns = 0, runaways = 0, failures = 0
    private var configChanges = 0, autoFlushes = 0, resent = 0
    private var lastReport = Date()
    /// The output device's own latency. Audio queued less than this far
    /// ahead of the playhead arrives too late and the renderer silently drops
    /// it (measured on AirPods: 171 ms reported, silence at 170 ms, fine at 200).
    private var outputLatency = 0.0
    /// How far ahead to keep audio: output latency plus a margin. Excess
    /// left over from the output waking up is trimmed down to this.
    /// UserDefaults `targetLead` (seconds) overrides it; `trimLatency` = NO
    /// turns trimming off. Both are re-read once a second.
    private var targetLead = 0.0
    private var trimming = true
    /// Headroom over the output latency. Bluetooth makes the playhead
    /// jitter by about ±50 ms; at 60 ms of margin that jitter kept tripping
    /// the underrun and trim corrections, each an audible skip (heard as the
    /// song slowing down and speeding up). 150 ms rides it out.
    static let margin = 0.15
    /// Re-sent audio must land at least this far past the output latency,
    /// or the playhead jitter makes it late.
    private static let resendSafety = 0.06
    private var windowMin = Double.infinity
    private var windowStart = Date()
    /// When the timeline last (re)started. Trimming only happens shortly
    /// after, to remove the output's wake-up delay; never in steady play.
    private var startedAt = Date()
    private var toSkip = 0
    private var trims = 0
    private var resyncs = 0
    private var recentUnderruns: [Date] = []

    private let logging = args.contains("--log")

    /// Speed check against the host clock, every 250 ms: how fast the
    /// renderer's clock runs and how fast the tap delivers. Normally both
    /// are 1.000; during a mode switch one of them isn't, and which one says
    /// where the speed-up / slow-down comes from.
    private var speedMark: (host: Double, clock: Double, written: Int)?
    private var worstClock = 1.0, worstTap = 1.0
    private var tapMark: (host: Double, written: Int)?

    init() {
        staging = .allocate(capacity: chunk * 2)
        history = .allocate(capacity: Int(historyFrames) * 2)
        history.initialize(repeating: 0, count: Int(historyFrames) * 2)
        fadeFrom = .allocate(capacity: fadeInLength * 2)
        fadeFrom.initialize(repeating: 0, count: fadeInLength * 2)
        configureRenderer()
    }

    /// Sets up the current renderer and synchronizer. In init, or on the
    /// player's queue when replacing a failed pair.
    private func configureRenderer() {
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        // When the AirPods change their buffering (switching to or from Head
        // Tracked adds or removes ~80 ms), the renderer catches up by playing
        // slower or faster for a few seconds (measured: the output drifts
        // 70-95 ms against Spotify). Varispeed makes that a plain resample, a
        // brief pitch dip that settles sooner; the default time-domain
        // stretch warbles. Steady playback runs at rate 1 and is untouched.
        renderer.audioTimePitchAlgorithm = .varispeed
        synchronizer.addRenderer(renderer)
        // Start the clock right away instead of waiting for the output to
        // wake up; otherwise that wait (~200 ms on AirPods) becomes
        // permanent extra delay.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false

        // Both notifications arrive on arbitrary threads; handle them on
        // the player's queue so they're serialized with enqueueing.
        let center = NotificationCenter.default
        for o in observers { center.removeObserver(o) }
        observers = [
            center.addObserver(forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
                               object: renderer, queue: nil) { [weak self] _ in
                self?.queue.async { self?.outputConfigurationChanged() }
            },
            center.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                               object: renderer, queue: nil) { [weak self] note in
                let time = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
                self?.queue.async { self?.flushedAutomatically(at: time) }
            },
        ]
    }

    /// Player queue: a fresh renderer and synchronizer for a failed pair.
    private func replaceRenderer() {
        synchronizer.setRate(0, time: .zero)
        renderer.flush()
        synchronizer.removeRenderer(renderer, at: .zero, completionHandler: nil)
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        configureRenderer()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        stop()
        staging.deallocate()
        history.deallocate()
        fadeFrom.deallocate()
    }

    /// Seconds queued ahead of the playhead (for the smoke test / log).
    var queuedAhead: Double {
        queue.sync { started ? Double(nextFrame - nowFrame()) / sampleRate : 0 }
    }

    /// Underrun jumps and runaway skips so far (for the smoke test).
    var glitches: Int { queue.sync { underruns + runaways } }

    var failed: Error? { queue.sync { renderer.status == .failed ? renderer.error : nil } }

    func start(sampleRate: Double, outputLatency: Double = 0, deviceUID: String? = nil) throws {
        stop()
        // (Pinning audioOutputDeviceUniqueID to the output was tried against
        // the "speeding up / slowing down" report: no change, so it's left
        // on the system default. Setting it to nil throws.)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        // Tagging it stereo is what lets macOS spatialize it as stereo.
        var layout = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                                        mChannelBitmap: [], mNumberChannelDescriptions: 0,
                                        mChannelDescriptions: AudioChannelDescription())
        var description: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), "describe audio")

        queue.sync {
            format = description
            self.sampleRate = sampleRate
            ring.skipAll()
            nextFrame = 0
            started = false
            cushion = 0
            self.outputLatency = outputLatency
            readSettings()
        }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    /// The output's latency changed under us (a mode switch can do that):
    /// the "too late to play" line moves with it.
    func setOutputLatency(_ latency: Double) {
        queue.async { [self] in
            guard abs(latency - outputLatency) > 0.0005 else { return }
            event(String(format: "output latency %.0f -> %.0f ms", outputLatency * 1000, latency * 1000))
            outputLatency = latency
            readSettings()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            synchronizer.setRate(0, time: .zero)
            renderer.flush()
            bufferStarts.removeAll()
            reenqueuing = false
            waking = nil
            generation += 1
            started = false
        }
    }

    // MARK: Pumping the tap into the renderer

    /// Moves whatever the tap delivered into the renderer, keeping the queue
    /// `targetLead` seconds ahead of the playhead.
    private func pump() {
        guard format != nil else { return }
        if Date().timeIntervalSince(lastReport) >= 1 {
            lastReport = Date()
            readSettings()
            if logging {
                let ahead = started ? Double(nextFrame - nowFrame()) / sampleRate : 0
                log(String(format: "player ahead %.0f ms target %.0f ms trims %d underruns %d resyncs %d runaways %d overflows %d failures %d config %d autoflush %d resent %d speed clock %.4f tap %.4f",
                    ahead * 1000, targetLead * 1000, trims, underruns, resyncs, runaways, ring.overflows, failures, configChanges, autoFlushes, resent, worstClock, worstTap))
                worstClock = 1; worstTap = 1
            }
        }
        measureSpeed()
        if reenqueuing { return }
        if renderer.status == .failed || pretendFailed {
            // e.g. the output went away, or coreaudiod restarted. A failed
            // renderer stays failed, so swap in a new one (at most once a
            // second, so one that can't play right now isn't churned).
            guard Date().timeIntervalSince(lastReplaced) > 1 else { return }
            lastReplaced = Date()
            pretendFailed = false
            failures += 1
            event("renderer failed (\(renderer.error.map { "\($0)" } ?? "?")): replacing it")
            replaceRenderer()
            restartTimeline()
        }
        let rate = sampleRate
        if !started {
            guard Double(ring.available) >= lead * rate else { return }
            synchronizer.setRate(0, time: .zero)
            renderer.flush()
            bufferStarts.removeAll()
            nextFrame = 0
            beginWaking()
            _ = wake()                              // queue the first silence,
            synchronizer.setRate(1, time: .zero)    // then start the clock
            started = true
            startedAt = Date()
            return
        }
        if waking != nil {
            guard wake() else { return }
        } else {
            let now = nowFrame()
            while let first = bufferStarts.first, first < now - Int64(rate) { bufferStarts.removeFirst() }
            let ahead = Double(nextFrame - now) / rate
            if ahead < outputLatency + 0.005 {
                // Too close to be played: these buffers would be dropped.
                // Jump forward to the target (a short gap) and keep a bit
                // more in hand from now on.
                nextFrame = now + Int64((targetLead + cushion) * rate)
                fadeIn()
                cushion = min(cushion + 0.02, 0.3)
                underruns += 1
                event(String(format: "underrun (%.0f ms ahead): jumped forward", ahead * 1000))
                // A burst of underruns means the clock and the incoming audio
                // disagree (seen once: ~7% apart for six minutes, the clock
                // jumping 300 ms every 5 s, heard as the song slowing and
                // lurching). Patching each one never converges; start the
                // timeline over instead.
                recentUnderruns = recentUnderruns.filter { Date().timeIntervalSince($0) < 5 } + [Date()]
                if recentUnderruns.count >= 5 {
                    recentUnderruns.removeAll()
                    resyncs += 1
                    event("underrun burst: starting the timeline over")
                    restartTimeline()
                    return
                }
            } else if trimming, Date().timeIntervalSince(startedAt) < 10 {
                // Trim the excess left by the output waking up: once the
                // smallest lead over a full second is above target, drop that
                // much incoming audio (crossfaded, so a tiny skip, no click).
                windowMin = min(windowMin, ahead)
                if Date().timeIntervalSince(windowStart) >= 1 {
                    // Only one trim at a time: dropping N ms takes N ms of
                    // incoming audio, and stacking trims would overshoot.
                    if toSkip == 0, windowMin > targetLead + cushion + 0.03 {
                        toSkip = Int((windowMin - targetLead - cushion) * rate)
                        skipCaptured = 0
                        trims += 1
                        event(String(format: "trim: skipping %.0f ms of excess delay", Double(toSkip) / rate * 1000))
                    }
                    windowMin = .infinity
                    windowStart = Date()
                }
            }
            if ahead > max(1.5, targetLead + cushion + 1) {
                // Runaway drift only. What sits queued at steady state is
                // what the renderer needs to cover output latency (about
                // 110-300 ms on AirPods, measured); trimming it makes every
                // buffer late and the renderer drops them: silence.
                runaways += 1
                event(String(format: "runaway (%.0f ms ahead): starting the timeline over", ahead * 1000))
                ring.skipAll()
                restartTimeline()
                return
            }
        }

        if toSkip > 0 {
            while toSkip > 0 && ring.available > 0 {
                let n = ring.read(into: staging, frames: min(chunk, toSkip))
                // Keep the start of what's dropped: the cut fades out of it.
                let keep = min(n, fadeLength - skipCaptured)
                if keep > 0 {
                    (fadeFrom + skipCaptured * 2).update(from: staging, count: keep * 2)
                    skipCaptured += keep
                }
                toSkip -= n
            }
            if toSkip <= 0 {   // judge the result with a fresh window
                toSkip = 0
                if skipCaptured > 0 { fadeTotal = skipCaptured; fadeDone = 0 }
                windowMin = .infinity
                windowStart = Date()
            }
        }

        if toSkip == 0 {
            while ring.available > 0 && renderer.isReadyForMoreMediaData {
                let n = ring.read(into: staging, frames: chunk)
                guard n > 0 else { break }
                applyFade(frames: n)
                guard enqueue(frames: n) else { break }
            }
        }
    }

    private func beginWaking() {
        waking = Date()
        clockSamples.removeAll()
        toSkip = 0
    }

    /// One pump while the output wakes up: keep silence queued, drop what
    /// the tap delivers, and once the clock runs at real time, place the
    /// music `targetLead` ahead. Returns true when normal playback can go on.
    private func wake() -> Bool {
        guard let since = waking else { return true }
        let rate = sampleRate
        ring.skipAll()
        let now = nowFrame()
        // Anything closer than the output latency would be dropped anyway.
        nextFrame = max(nextFrame, now + Int64((outputLatency + Self.resendSafety) * rate))
        let want = now + Int64(targetLead * rate)
        while nextFrame < want, renderer.isReadyForMoreMediaData {
            let n = Int(min(Int64(chunk), want - nextFrame))
            staging.update(repeating: 0, count: n * 2)
            guard enqueue(frames: n) else { break }
        }
        let waited = Date().timeIntervalSince(since)
        let awake = started && clockRunsSteadily()
        guard awake || waited > 2 else { return false }
        waking = nil
        nextFrame = max(nextFrame, nowFrame() + Int64(targetLead * rate))
        fadeIn()
        // The trim stays as a safety net for whatever the clock does next.
        startedAt = Date()
        windowMin = .infinity
        windowStart = Date()
        event(String(format: awake ? "output awake after %.0f ms: music starts %.0f ms behind Spotify"
                                   : "output still waking after %.0f ms: starting anyway, %.0f ms behind Spotify",
                     waited * 1000, Double(nextFrame - nowFrame()) / rate * 1000))
        return true
    }

    /// True once the clock has run at about real time for the last 40 ms.
    private func clockRunsSteadily() -> Bool {
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let clock = synchronizer.currentTime().seconds
        clockSamples.append((host, clock))
        clockSamples.removeAll { host - $0.host > 0.25 }
        guard let old = clockSamples.last(where: { host - $0.host >= 0.04 }) else { return false }
        let speed = (clock - old.clock) / (host - old.host)
        return speed > 0.8 && speed < 1.25
    }

    /// Enqueues the `frames` frames in `staging` at `nextFrame`, remembering
    /// them so they can be sent again.
    @discardableResult
    private func enqueue(frames n: Int, remember: Bool = true) -> Bool {
        guard let format, let buffer = makeBuffer(frames: n, at: nextFrame, format: format) else { return false }
        if remember {
            for i in 0..<n {
                let slot = historySlot(nextFrame + Int64(i))
                history[slot] = staging[i * 2]
                history[slot + 1] = staging[i * 2 + 1]
            }
        }
        renderer.enqueue(buffer)
        bufferStarts.append(nextFrame)
        nextFrame += Int64(n)
        return true
    }

    /// Where timeline frame `frame` sits in `history`. Frames shouldn't go
    /// negative, but if one did, a plain modulo would index before the buffer.
    private func historySlot(_ frame: Int64) -> Int {
        let m = frame % historyFrames
        return Int(m < 0 ? m + historyFrames : m) * 2
    }

    private func nowFrame() -> Int64 {
        CMTimeConvertScale(synchronizer.currentTime(), timescale: timescale, method: .roundHalfAwayFromZero).value
    }

    /// Earliest timeline frame that can still be queued and actually play.
    private func earliestPlayable() -> Int64 {
        nowFrame() + Int64((outputLatency + Self.resendSafety) * sampleRate)
    }

    private func restartTimeline() {
        renderer.flush()
        bufferStarts.removeAll()
        reenqueuing = false
        waking = nil
        generation += 1
        cushion = 0
        toSkip = 0
        started = false
    }

    private func measureSpeed() {
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let clock = started ? synchronizer.currentTime().seconds : 0
        let written = ring.totalWritten
        guard started, let mark = speedMark else {
            speedMark = (host, clock, written)
            tapMark = nil
            return
        }
        let dt = host - mark.host
        guard dt >= 0.25 else { return }
        speedMark = (host, clock, written)
        // Ignore windows our own jumps (re-anchors, restarts) fall in.
        let clockSpeed = (clock - mark.clock) / dt
        guard clockSpeed > 0.5, clockSpeed < 1.5 else { return }
        if abs(clockSpeed - 1) > abs(worstClock - 1) { worstClock = clockSpeed }
        // The tap arrives in IO-sized lumps; judge it over a whole second.
        if let t = tapMark, host - t.host >= 1 {
            let tapSpeed = Double(written - t.written) / sampleRate / (host - t.host)
            tapMark = (host, written)
            if abs(tapSpeed - 1) > abs(worstTap - 1) { worstTap = tapSpeed }
            if abs(tapSpeed - 1) > 0.01 {
                event(String(format: "speed: tap delivering at %.4f", tapSpeed))
            }
        } else if tapMark == nil {
            tapMark = (host, written)
        }
        if abs(clockSpeed - 1) > 0.004 {
            event(String(format: "speed: renderer clock running at %.4f, ahead %.0f ms",
                         clockSpeed, Double(nextFrame - nowFrame()) / sampleRate * 1000))
        }
    }

    // MARK: Mode switches

    /// Test hooks (`--transparency --simulate`): run the mode-switch
    /// handlers by hand, since only a person can flip Control Center.
    func simulateConfigurationChange() { queue.async { self.outputConfigurationChanged() } }
    func simulateAutomaticFlush() { queue.async { self.renderer.flush(); self.flushedAutomatically(at: nil) } }
    /// Takes the failed-renderer path (replace it, start over) on the next pump.
    func simulateFailure() { queue.async { self.pretendFailed = true } }
    private var pretendFailed = false

    /// Control Center's spatial setting changed (or something else
    /// reconfigured the output). Replace what's queued past the point that
    /// can still change with the very same samples, so the new configuration
    /// takes over seamlessly.
    private func outputConfigurationChanged() {
        configChanges += 1
        guard started, !reenqueuing else { event("output configuration changed (not playing)"); return }
        let from = earliestPlayable()
        guard let t = bufferStarts.first(where: { $0 >= from }), t < nextFrame else {
            event("output configuration changed: nothing queued far enough ahead to re-send")
            return
        }
        let end = nextFrame, gen = generation
        reenqueuing = true
        renderer.flush(fromSourceTime: CMTime(value: t, timescale: timescale)) { [weak self] ok in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                self.reenqueuing = false
                if ok {
                    self.resend(from: t, to: end)
                    self.event(String(format: "output configuration changed: re-sent %.0f ms", Double(end - t) / self.sampleRate * 1000))
                } else {
                    // Refused (too close to the playhead, it says). Leave
                    // the queue alone: new buffers carry the new setup
                    // anyway, and starting over costs ~1 s of silence
                    // while the AirPods wake up again (measured).
                    self.event("output configuration changed: partial flush refused, carrying on")
                }
            }
        }
    }

    /// The renderer threw away part of its queue by itself (a route or
    /// configuration change). Apple: flush the rest, serialized with
    /// enqueueing, then enqueue from the timebase's current time, which
    /// keeps running. Measured: after a flush the clock jumps or stalls for
    /// a few hundred ms, so this waits until it runs steadily again (the same
    /// wake-up as a fresh start) before picking where the audio resumes.
    /// Stopping and restarting the clock instead costs ~1 s of silence.
    private func flushedAutomatically(at time: CMTime?) {
        autoFlushes += 1
        guard started else { event("flushed automatically (not playing)"); return }
        renderer.flush()
        bufferStarts.removeAll()
        reenqueuing = false
        generation += 1   // any partial flush in flight is moot now
        nextFrame = nowFrame()
        beginWaking()
        let at = time.map { String(format: " at %.3f s", $0.seconds) } ?? ""
        event("flushed automatically\(at): resuming on the running clock")
    }

    /// Enqueues `history[from..<to]` again at the same timeline positions.
    private func resend(from: Int64, to end: Int64) {
        bufferStarts.removeAll { $0 >= from }
        nextFrame = from
        while nextFrame < end {
            let n = Int(min(Int64(chunk), end - nextFrame))
            for i in 0..<n {
                let slot = historySlot(nextFrame + Int64(i))
                staging[i * 2] = history[slot]
                staging[i * 2 + 1] = history[slot + 1]
            }
            // No fade: history holds these exactly as first sent (any fade
            // already in them), and a fade still in progress belongs to the
            // new frames that follow, not to these.
            guard enqueue(frames: n, remember: false) else {
                // Shouldn't happen; skip ahead rather than leave a hole
                // the timeline thinks is filled.
                nextFrame = end
                break
            }
        }
        resent += 1
    }

    // MARK: Declicking

    /// The next frames enqueued fade in from silence.
    private func fadeIn() {
        fadeFrom.update(repeating: 0, count: fadeInLength * 2)
        fadeTotal = fadeInLength
        fadeDone = 0
    }

    /// Raised-cosine crossfade (gains sum to 1) from `fadeFrom` into the
    /// frames in `staging`. Over a few ms the two sides are mostly
    /// correlated, and an equal-power fade bumped a steady tone by 1.36x.
    private func applyFade(frames n: Int) {
        guard fadeTotal > 0 else { return }
        let k = min(n, fadeTotal - fadeDone)
        for i in 0..<k {
            let p = fadeDone + i
            let theta = (Double(p) + 0.5) / Double(fadeTotal) * .pi / 2
            let b = Float(sin(theta) * sin(theta)), a = 1 - b
            staging[i * 2] = fadeFrom[p * 2] * a + staging[i * 2] * b
            staging[i * 2 + 1] = fadeFrom[p * 2 + 1] * a + staging[i * 2 + 1] * b
        }
        fadeDone += k
        if fadeDone >= fadeTotal { fadeTotal = 0; fadeDone = 0 }
    }

    // MARK: Helpers

    private func readSettings() {
        let d = UserDefaults.standard
        let override = d.double(forKey: "targetLead")
        targetLead = override > 0 ? override : outputLatency + Self.margin
        trimming = d.object(forKey: "trimLatency") as? Bool ?? true
        // Experiment: how the renderer stretches audio when it changes speed
        // to re-sync (`defaults write com.srode.spatial timePitch spectral |
        // timeDomain | varispeed`). Unset leaves Apple's default.
        if let name = d.string(forKey: "timePitch") {
            let algorithm: AVAudioTimePitchAlgorithm? = switch name {
                case "spectral": .spectral
                case "timeDomain": .timeDomain
                case "varispeed": .varispeed
                default: nil
            }
            if let algorithm, renderer.audioTimePitchAlgorithm != algorithm {
                renderer.audioTimePitchAlgorithm = algorithm
                event("time pitch algorithm: \(algorithm.rawValue)")
            }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func log(_ line: String) {
        FileHandle.standardError.write("\(Self.clock.string(from: Date())) \(line)\n".data(using: .utf8)!)
    }

    /// Something that changes what's heard: always worth a timestamped line.
    private func event(_ line: String) {
        if logging { log("EVENT " + line) }
    }

    private func makeBuffer(frames: Int, at frame: Int64, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = frames * 2 * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: staging, blockBuffer: block,
                                            offsetIntoDestination: 0, dataLength: bytes) == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: CMTime(value: frame, timescale: timescale),
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
