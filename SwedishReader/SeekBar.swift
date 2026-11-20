import SwiftUI
import UIKit

/// Playback position bar: drag the knob, or tap anywhere on the bar to jump there.
///
/// Wraps UISlider rather than SwiftUI's Slider because SwiftUI's doesn't jump on tap, and a
/// custom drag gesture would compete with the page-swiping gesture of the reader.
struct SeekBar: View {
    var currentTime: TimeInterval
    var duration: TimeInterval
    var onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(spacing: 2) {
            SliderView(value: currentTime, maximum: duration, onSeek: onSeek)
            HStack {
                Text(Self.format(currentTime))
                Spacer()
                Text("-" + Self.format(max(duration - currentTime, 0)))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
    }
}

private struct SliderView: UIViewRepresentable {
    var value: TimeInterval
    var maximum: TimeInterval
    var onSeek: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        // Seek once the finger lifts, not continuously: repeated jumps while dragging make the audio stutter.
        slider.addTarget(context.coordinator, action: #selector(Coordinator.released(_:)), for: [.touchUpInside, .touchUpOutside])
        slider.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.maximumValue = Float(max(maximum, 0.01))
        // Don't yank the knob away from the finger while it's being dragged.
        if !slider.isTracking { slider.value = Float(value) }
    }

    final class Coordinator: NSObject {
        var parent: SliderView

        init(_ parent: SliderView) { self.parent = parent }

        @objc func released(_ slider: UISlider) {
            parent.onSeek(TimeInterval(slider.value))
        }

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let slider = tap.view as? UISlider, slider.bounds.width > 0 else { return }
            let fraction = min(max(tap.location(in: slider).x / slider.bounds.width, 0), 1)
            let time = TimeInterval(fraction) * TimeInterval(slider.maximumValue)
            slider.setValue(Float(time), animated: true)
            parent.onSeek(time)
        }
    }
}
