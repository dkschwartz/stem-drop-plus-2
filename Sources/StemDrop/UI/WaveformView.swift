import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    var height: CGFloat = 38

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            guard !samples.isEmpty, samples.contains(where: { $0 > 0 }) else {
                var flatLine = Path()
                flatLine.move(to: CGPoint(x: 4, y: middle))
                flatLine.addLine(to: CGPoint(x: max(4, size.width - 4), y: middle))
                context.stroke(flatLine, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
                return
            }

            let spacing = size.width / CGFloat(samples.count)
            var waveform = Path()
            for (index, sample) in samples.enumerated() {
                let x = (CGFloat(index) + 0.5) * spacing
                let halfHeight = max(0.5, CGFloat(sample) * (size.height / 2 - 3))
                waveform.move(to: CGPoint(x: x, y: middle - halfHeight))
                waveform.addLine(to: CGPoint(x: x, y: middle + halfHeight))
            }
            context.stroke(waveform, with: .color(.accentColor), lineWidth: 1)
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.07))
        .borderedBox(cornerRadius: 4)
        .accessibilityLabel(samples.contains(where: { $0 > 0 }) ? "Track waveform" : "Silent track")
    }
}
