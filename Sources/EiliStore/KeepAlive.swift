import AVFAudio
import Foundation

/// 靜音音頻保活（參考 SideInstaller/KeepAlive.swift）
/// 讓 App 在後台不被 iOS 掛起，配合 Heartbeat 使用
public class KeepAlive {
    public static let shared = KeepAlive()
    
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioRunning = false
    
    private init() {}
    
    public func start() {
        guard !audioRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            
            let format = engine.outputNode.inputFormat(forBus: 0)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            
            let frames = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            // 靜音：buffer 全 0
            
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioRunning = true
        } catch {
            audioRunning = false
        }
    }
    
    public func stop() {
        guard audioRunning else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        audioRunning = false
    }
    
    public var isRunning: Bool { audioRunning }
}
