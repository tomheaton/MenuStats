import AppKit

struct History {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

struct GraphSeries {
    var name: String
    var color: NSColor
    var values: [Double]
}

// An area graph sized to sit in a menu item. The newest sample is at the right
// edge, and a series shorter than `capacity` starts partway across.
final class GraphView: NSView {
    var title = ""
    var series: [GraphSeries] = [] { didSet { needsDisplay = true } }
    var range: ClosedRange<Double> = 0...1
    var stacked = false
    var capacity = 90

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let legend = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        for series in series where !series.name.isEmpty {
            legend.append(NSAttributedString(string: "   ●", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: series.color]))
            legend.append(NSAttributedString(string: " \(series.name)", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        legend.draw(at: NSPoint(x: bounds.minX + 14, y: bounds.maxY - 16))

        let plot = NSRect(x: bounds.minX + 14, y: bounds.minY + 3, width: bounds.width - 28, height: bounds.height - 22)
        let frame = NSBezierPath(roundedRect: plot, xRadius: 5, yRadius: 5)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        frame.fill()

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        let step = plot.width / CGFloat(capacity - 1)
        func point(_ index: Int, _ value: Double) -> NSPoint {
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            return NSPoint(x: plot.minX + CGFloat(index) * step, y: plot.minY + plot.height * CGFloat(min(max(fraction, 0), 1)))
        }

        var stackTops = [Double](repeating: range.lowerBound, count: capacity)
        for series in series {
            let values = Array(series.values.suffix(capacity))
            guard values.count > 1 else { continue }
            let first = capacity - values.count
            let bottoms = values.indices.map { stacked ? stackTops[first + $0] : range.lowerBound }
            let tops = values.indices.map { stacked ? bottoms[$0] + values[$0] : values[$0] }

            let line = NSBezierPath()
            line.move(to: point(first, tops[0]))
            for index in values.indices.dropFirst() { line.line(to: point(first + index, tops[index])) }
            let area = line.copy() as! NSBezierPath
            for index in values.indices.reversed() { area.line(to: point(first + index, bottoms[index])) }
            area.close()

            // Overlapping fills muddy each other, so unstacked areas stay faint.
            series.color.withAlphaComponent(stacked ? 0.3 : 0.1).setFill()
            area.fill()
            series.color.setStroke()
            line.lineWidth = 1.2
            line.stroke()
            if stacked {
                for index in values.indices { stackTops[first + index] = tops[index] }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

// A monochrome template image, so the menu bar tints and dims it like other
// items. Values are fractions from 0 to 1.
func sparkline(_ values: [Double], samples: Int = 20, size: NSSize = NSSize(width: 26, height: 15)) -> NSImage {
    let values = Array(values.suffix(samples))
    let image = NSImage(size: size, flipped: false) { rect in
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let frame = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
        NSColor.black.withAlphaComponent(0.35).setStroke()
        frame.lineWidth = 1
        frame.stroke()
        guard values.count > 1 else { return true }

        let plot = box.insetBy(dx: 1.5, dy: 1.5)
        let step = plot.width / CGFloat(samples - 1)
        let first = samples - values.count
        let area = NSBezierPath()
        area.move(to: NSPoint(x: plot.minX + CGFloat(first) * step, y: plot.minY))
        for (index, value) in values.enumerated() {
            area.line(to: NSPoint(x: plot.minX + CGFloat(first + index) * step, y: plot.minY + plot.height * CGFloat(min(max(value, 0), 1))))
        }
        area.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        area.close()
        NSColor.black.setFill()
        area.fill()
        return true
    }
    image.isTemplate = true
    return image
}
