import AVFoundation
import Combine
import UIKit

/// 使用公开音频 API 的尽力保活；不具备进程复活或无限后台执行保证。
@MainActor
final class BackgroundAudio: ObservableObject {
    @Published private(set) var status = "未启用"
    @Published private(set) var isPlaying = false
    var log: (String) -> Void = { _ in }

    private var player: AVAudioPlayer?
    private var wantsAudio = false
    private var enabled = false
    private var taskActive = false
    private var interrupted = false
    private var ownsSession = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.interruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.player = nil
                self.ownsSession = false
                self.isPlaying = false
                self.log("[后台] 音频服务重置，重新检查保活条件。\n")
                if self.wantsAudio && !self.interrupted { self.start() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsAudio, !self.interrupted else { return }
                if self.player?.isPlaying != true { self.start() }
            }
        })
    }

    func update(enabled: Bool, taskActive: Bool, foreground: Bool) {
        self.enabled = enabled
        self.taskActive = taskActive
        wantsAudio = enabled && taskActive && !foreground
        if foreground { interrupted = false }
        if wantsAudio {
            if !interrupted { start() }
        } else {
            stop()
            status = !enabled ? "未启用" : (taskActive ? "前台待机" : "等待运行任务")
        }
    }

    private func start() {
        guard wantsAudio, !interrupted else { return }
        if player?.isPlaying == true { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            ownsSession = true
            if player == nil {
                let audio = try AVAudioPlayer(data: Self.silentWave(), fileTypeHint: AVFileType.wav.rawValue)
                audio.numberOfLoops = -1
                audio.volume = 0.01
                audio.prepareToPlay()
                player = audio
            }
            guard player?.play() == true else {
                throw NSError(domain: "PyPocket.Audio", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "播放器没有开始播放"])
            }
            isPlaying = true
            status = "音频保活中"
            log("[后台] 已开始循环静音音频；实际服务状态仍需单独检查。\n")
        } catch {
            stop()
            status = "保活失败"
            log("[后台] 无法启动：\(error.localizedDescription)\n")
        }
    }

    private func stop() {
        let wasPlaying = isPlaying
        player?.stop()
        isPlaying = false
        if ownsSession {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                log("[后台] 释放音频会话失败：\(error.localizedDescription)\n")
            }
            ownsSession = false
        }
        if wasPlaying { log("[后台] 已停止静音音频。\n") }
    }

    private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interrupted = true
            player?.pause()
            isPlaying = false
            if wantsAudio {
                status = "音频被系统中断"
                log("[后台] 来电或其他音频会话中断，保活可能失效。\n")
            }
        case .ended:
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume) {
                interrupted = false
                if wantsAudio { start() }
            } else if wantsAudio {
                status = "等待返回前台恢复"
                log("[后台] 系统未允许恢复音频，请返回 App 检查任务。\n")
            }
        @unknown default:
            break
        }
    }

    private static func silentWave() -> Data {
        // 一秒、单声道、16 位零采样 PCM；不是通过把有声媒体音量调零伪装静音。
        let sampleRate: UInt32 = 8000
        let payloadSize = sampleRate * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36) + payloadSize); text("WAVE")
        text("fmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(sampleRate); number(sampleRate * 2); number(UInt16(2)); number(UInt16(16))
        text("data"); number(payloadSize)
        data.append(Data(count: Int(payloadSize)))
        return data
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
