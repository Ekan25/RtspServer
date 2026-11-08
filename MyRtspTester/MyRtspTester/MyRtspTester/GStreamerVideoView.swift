import AppKit
import SwiftUI

struct GStreamerVideoView: NSViewRepresentable {
    let player: GStreamerPlayerViewModel

    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        view.player = player
        DispatchQueue.main.async {
            player.attachRenderView(view)
        }
        return view
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        nsView.player = player
        player.attachRenderView(nsView)
    }

    static func dismantleNSView(_ nsView: VideoHostView, coordinator: ()) {
        nsView.player?.detachRenderView()
    }

    func makeCoordinator() {}
}

final class VideoHostView: NSView {
    weak var player: GStreamerPlayerViewModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    }

    override func layout() {
        super.layout()
        player?.attachRenderView(self)
    }
}
