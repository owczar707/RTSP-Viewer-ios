import SwiftUI
import UIKit

/// Hosts the player's video view inside a scroll view: pinch to zoom (up to 8×), drag to pan,
/// double-tap to zoom in / reset.
struct ZoomableVideoView: UIViewRepresentable {
    let player: StreamPlayer

    func makeUIView(context: Context) -> ZoomingScrollView {
        ZoomingScrollView(videoContentView: player.videoView)
    }

    func updateUIView(_ uiView: ZoomingScrollView, context: Context) {}
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let videoContentView: UIView
    private var lastLayoutSize: CGSize = .zero

    init(videoContentView: UIView) {
        self.videoContentView = videoContentView
        super.init(frame: .zero)

        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .black
        clipsToBounds = true

        // The video view may come from a previous (e.g. non-fullscreen) container.
        videoContentView.removeFromSuperview()
        videoContentView.transform = .identity
        addSubview(videoContentView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard videoContentView.superview === self, bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        // Size changed (rotation, fullscreen) – reset the zoom and fit the video again.
        setZoomScale(minimumZoomScale, animated: false)
        videoContentView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        videoContentView.superview === self ? videoContentView : nil
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: videoContentView)
        let scale: CGFloat = 3
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        let rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        zoom(to: rect, animated: true)
    }
}
