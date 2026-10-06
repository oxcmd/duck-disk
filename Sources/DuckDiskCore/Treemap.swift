import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing and van Wijk): rectangles whose areas are proportional to the values
/// and whose shapes stay close to squares, so sizes can be compared at a glance.
public enum Treemap {
    /// Lays out `values` (positive, largest first) inside `rect`. Returns one rect per value, in the same order.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return rects }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max(0, $0) * scale }

        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            // Grow the row while it makes the worst aspect ratio better.
            var end = start + 1
            var rowSum = areas[start]
            var best = worstRatio(largest: areas[start], smallest: areas[start], sum: rowSum, side: side)
            while end < areas.count {
                let candidate = rowSum + areas[end]
                let ratio = worstRatio(largest: areas[start], smallest: areas[end], sum: candidate, side: side)
                if ratio > best { break }
                best = ratio
                rowSum = candidate
                end += 1
            }

            if remaining.width >= remaining.height {
                // Column along the left edge.
                let width = rowSum / Double(remaining.height)
                var y = Double(remaining.minY)
                for i in start..<end {
                    let height = width > 0 ? areas[i] / width : 0
                    rects[i] = CGRect(x: Double(remaining.minX), y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // Row along the top edge.
                let height = rowSum / Double(remaining.width)
                var x = Double(remaining.minX)
                for i in start..<end {
                    let width = height > 0 ? areas[i] / height : 0
                    rects[i] = CGRect(x: x, y: Double(remaining.minY), width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return rects
    }

    /// The worst width/height ratio in a row of areas laid along a side of length `side`.
    static func worstRatio(largest: Double, smallest: Double, sum: Double, side: Double) -> Double {
        guard sum > 0, smallest > 0 else { return .infinity }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * largest / sum2, sum2 / (s2 * smallest))
    }
}
