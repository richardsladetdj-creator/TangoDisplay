import SwiftUI

struct LevelMeterView: View {
    @ObservedObject var meter: AudioLevelMeter

    static let totalWidth: CGFloat = 44 + 44 + 26 + 8 + 8

    private let barWidth:   CGFloat = 44
    private let scaleWidth: CGFloat = 26
    private let padding:    CGFloat = 8

    private static let dbMarks: [(String, CGFloat)] = [
        ("0",   1.000),
        ("-3",  0.708),
        ("-6",  0.501),
        ("-12", 0.251),
        ("-24", 0.063)
    ]

    private static let gradient = Gradient(stops: [
        .init(color: .green,  location: 0.0),
        .init(color: .yellow, location: 0.501),
        .init(color: .red,    location: 0.708)
    ])

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftBarCanvas
                scaleColumn
                rightBarCanvas
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: scaleWidth) {
                Text("L")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: barWidth, alignment: .center)
                Text("R")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: barWidth, alignment: .center)
            }
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
        .padding(padding)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.14, green: 0.14, blue: 0.16))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.6), lineWidth: 8)
                    .blur(radius: 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        )
        .contentShape(Rectangle())
        .onTapGesture { meter.resetClip() }
    }

    private var scaleColumn: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .topTrailing) {
                ForEach(Self.dbMarks, id: \.0) { label, frac in
                    Text(label)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .offset(y: max(0, h * (1.0 - frac) - 5))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: scaleWidth)
    }

    private func barCanvas(level: Float, peak: Float) -> some View {
        let bw = barWidth
        return Canvas { ctx, size in
            let h = size.height

            for (_, frac) in Self.dbMarks {
                let y = h * (1.0 - frac)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: bw, y: y))
                ctx.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }

            ctx.fill(
                Path(CGRect(x: 0, y: 0, width: bw, height: h)),
                with: .color(Color(nsColor: .separatorColor).opacity(0.3))
            )
            let levelH = h * CGFloat(min(level, 1.0))
            if levelH > 0 {
                ctx.fill(
                    Path(CGRect(x: 0, y: h - levelH, width: bw, height: levelH)),
                    with: .linearGradient(
                        Self.gradient,
                        startPoint: CGPoint(x: 0, y: h),
                        endPoint:   CGPoint(x: 0, y: 0)
                    )
                )
            }
            if peak > 0 {
                let peakY = h * (1.0 - CGFloat(min(peak, 1.0)))
                ctx.fill(
                    Path(CGRect(x: 0, y: peakY, width: bw, height: 2)),
                    with: .color(peak >= 1.0 ? .red : .white)
                )
            }
        }
        .frame(width: barWidth)
    }

    private var leftBarCanvas:  some View { barCanvas(level: meter.leftLevel,  peak: meter.leftPeak)  }
    private var rightBarCanvas: some View { barCanvas(level: meter.rightLevel, peak: meter.rightPeak) }
}
