import Foundation

/// Arithmetic and unit conversion typed straight into the search field.
public enum Calculator {
    public struct Answer: Equatable, Sendable {
        public let value: Double
        /// What the result line shows, e.g. "3.106856 mi".
        public let display: String
        /// What gets copied, without grouping separators or units.
        public let copyText: String
    }

    /// Returns nil unless the query is clearly a calculation: something has to be computed, not just a number.
    public static func evaluate(_ query: String) -> Answer? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.count <= 200 else { return nil }
        if let converted = convert(q) { return converted }
        // A lone word like "pi" or "e" is almost always the start of an app or file name.
        if q.allSatisfy(\.isLetter) { return nil }
        var parser = Parser(q)
        guard let value = parser.parseAll(), value.isFinite, parser.didCompute else { return nil }
        return Answer(value: value, display: format(value), copyText: plain(value))
    }

    // MARK: Formatting

    public static func format(_ v: Double) -> String {
        if v != 0 && (abs(v) >= 1e15 || abs(v) < 1e-9) {
            return String(format: "%.8g", v)
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = abs(v) >= 1 ? 8 : 12
        f.locale = Locale.current
        return f.string(from: NSNumber(value: rounded(v))) ?? plain(v)
    }

    public static func plain(_ v: Double) -> String {
        let r = rounded(v)
        if r == r.rounded(), abs(r) < 1e15 { return String(Int64(r)) }
        var s = String(format: "%.12g", r)
        if s.contains("e") { return s }
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Hides binary floating-point noise such as 0.1 + 0.2 = 0.30000000000000004.
    static func rounded(_ v: Double) -> Double {
        guard v != 0, v.isFinite else { return v }
        let digits = 12 - Int(floor(log10(abs(v)))) - 1
        guard digits > 0, digits < 300 else { return v }
        let scale = pow(10, Double(digits))
        return (v * scale).rounded() / scale
    }

    // MARK: Units

    static func convert(_ q: String) -> Answer? {
        let lower = q.lowercased()
            .replacingOccurrences(of: "fl oz", with: "floz")
            .replacingOccurrences(of: "°", with: "")
        var split: (String, String)?
        for word in [" to ", " in ", " as ", " into ", " -> ", " => "] {
            if let r = lower.range(of: word, options: .backwards) {
                split = (String(lower[..<r.lowerBound]), String(lower[r.upperBound...]))
                break
            }
        }
        guard let (left, right) = split else { return nil }
        let targetName = right.trimmingCharacters(in: .whitespaces)
        guard let target = units[targetName] else { return nil }

        // The source unit is the trailing run of unit characters on the left side.
        let trimmed = left.trimmingCharacters(in: .whitespaces)
        var unitStart = trimmed.endIndex
        while unitStart > trimmed.startIndex {
            let prev = trimmed[trimmed.index(before: unitStart)]
            if prev.isLetter || prev == "/" || prev == "µ" || prev == "\"" || prev == "'" {
                unitStart = trimmed.index(before: unitStart)
            } else { break }
        }
        let sourceName = String(trimmed[unitStart...])
        let amountText = trimmed[..<unitStart].trimmingCharacters(in: .whitespaces)
        guard let source = units[sourceName],
              type(of: source).baseUnit().symbol == type(of: target).baseUnit().symbol else { return nil }
        var parser = Parser(amountText.isEmpty ? "1" : amountText)
        guard let amount = parser.parseAll(), amount.isFinite else { return nil }
        let result = Measurement(value: amount, unit: source).converted(to: target).value
        guard result.isFinite else { return nil }
        return Answer(value: result, display: format(result) + " " + label(for: targetName, unit: target), copyText: plain(result))
    }

    static func label(for name: String, unit: Dimension) -> String {
        if unit is UnitTemperature { return unit.symbol }
        return unitLabels[name] ?? unit.symbol
    }

    static let unitLabels: [String: String] = [
        "floz": "fl oz", "cup": "cups", "cups": "cups", "tsp": "tsp", "tbsp": "tbsp",
        "day": "days", "days": "days", "d": "days", "week": "weeks", "weeks": "weeks", "w": "weeks",
        "year": "years", "years": "years", "yr": "years", "y": "years",
    ]

    static let units: [String: Dimension] = {
        var u: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String...) { for n in names { u[n] = unit } }
        add(UnitLength.millimeters, "mm", "millimeter", "millimeters", "millimetre", "millimetres")
        add(UnitLength.centimeters, "cm", "centimeter", "centimeters", "centimetre", "centimetres")
        add(UnitLength.meters, "m", "meter", "meters", "metre", "metres")
        add(UnitLength.kilometers, "km", "kilometer", "kilometers", "kilometre", "kilometres")
        add(UnitLength.micrometers, "µm", "um", "micrometer", "micrometers", "micron", "microns")
        add(UnitLength.inches, "in", "inch", "inches", "\"")
        add(UnitLength.feet, "ft", "foot", "feet", "'")
        add(UnitLength.yards, "yd", "yard", "yards")
        add(UnitLength.miles, "mi", "mile", "miles")
        add(UnitLength.nauticalMiles, "nmi", "nautical mile", "nautical miles")
        add(UnitMass.milligrams, "mg", "milligram", "milligrams")
        add(UnitMass.grams, "g", "gram", "grams")
        add(UnitMass.kilograms, "kg", "kilo", "kilos", "kilogram", "kilograms")
        add(UnitMass.metricTons, "t", "tonne", "tonnes")
        add(UnitMass.pounds, "lb", "lbs", "pound", "pounds")
        add(UnitMass.ounces, "oz", "ounce", "ounces")
        add(UnitMass.stones, "st", "stone", "stones")
        add(UnitVolume.milliliters, "ml", "milliliter", "milliliters", "millilitre", "millilitres")
        add(UnitVolume.centiliters, "cl")
        add(UnitVolume.deciliters, "dl")
        add(UnitVolume.liters, "l", "liter", "liters", "litre", "litres")
        add(UnitVolume.teaspoons, "tsp", "teaspoon", "teaspoons")
        add(UnitVolume.tablespoons, "tbsp", "tablespoon", "tablespoons")
        add(UnitVolume(symbol: "cup", converter: UnitConverterLinear(coefficient: 0.2365882365)), "cup", "cups") // US cup; Foundation's .cups is the 240 ml metric cup
        add(UnitVolume.fluidOunces, "floz")
        add(UnitVolume.pints, "pt", "pint", "pints")
        add(UnitVolume.quarts, "qt", "quart", "quarts")
        add(UnitVolume.gallons, "gal", "gallon", "gallons")
        add(UnitTemperature.celsius, "c", "celsius")
        add(UnitTemperature.fahrenheit, "f", "fahrenheit")
        add(UnitTemperature.kelvin, "k", "kelvin")
        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.kilometersPerHour, "kph", "kmh", "km/h")
        add(UnitSpeed.metersPerSecond, "m/s", "mps")
        add(UnitSpeed.knots, "kn", "knot", "knots")
        add(UnitDuration.milliseconds, "ms", "millisecond", "milliseconds")
        add(UnitDuration.seconds, "s", "sec", "secs", "second", "seconds")
        add(UnitDuration.minutes, "min", "mins", "minute", "minutes")
        add(UnitDuration.hours, "h", "hr", "hrs", "hour", "hours")
        add(UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), "d", "day", "days")
        add(UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)), "w", "wk", "week", "weeks")
        add(UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600)), "y", "yr", "year", "years")
        add(UnitInformationStorage.bits, "bit", "bits")
        add(UnitInformationStorage.bytes, "b", "byte", "bytes")
        add(UnitInformationStorage.kilobytes, "kb", "kilobyte", "kilobytes")
        add(UnitInformationStorage.megabytes, "mb", "megabyte", "megabytes")
        add(UnitInformationStorage.gigabytes, "gb", "gigabyte", "gigabytes")
        add(UnitInformationStorage.terabytes, "tb", "terabyte", "terabytes")
        add(UnitInformationStorage.petabytes, "pb", "petabyte", "petabytes")
        add(UnitInformationStorage.kibibytes, "kib")
        add(UnitInformationStorage.mebibytes, "mib")
        add(UnitInformationStorage.gibibytes, "gib")
        add(UnitInformationStorage.tebibytes, "tib")
        add(UnitEnergy.joules, "j", "joule", "joules")
        add(UnitEnergy.kilojoules, "kj", "kilojoule", "kilojoules")
        add(UnitEnergy.calories, "cal", "calorie", "calories")
        add(UnitEnergy.kilocalories, "kcal")
        add(UnitEnergy.kilowattHours, "kwh")
        add(UnitPressure.poundsForcePerSquareInch, "psi")
        add(UnitPressure.bars, "bar", "bars")
        add(UnitPressure.kilopascals, "kpa")
        add(UnitAngle.degrees, "deg", "degree", "degrees")
        add(UnitAngle.radians, "rad", "radian", "radians")
        return u
    }()

    // MARK: Expressions

    /// Recursive-descent parser. Supports + − × ÷ ^ % !, parentheses, implicit multiplication,
    /// "20% of 150", "a + b%" (adds b percent of a), hex/binary literals, and common functions.
    struct Parser {
        let chars: [Character]
        var i = 0
        var didCompute = false

        init(_ s: String) { chars = Array(s) }

        mutating func parseAll() -> Double? {
            guard let v = expression() else { return nil }
            skipSpaces()
            return i == chars.count ? v : nil
        }

        mutating func skipSpaces() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        mutating func peek() -> Character? {
            skipSpaces()
            return i < chars.count ? chars[i] : nil
        }

        mutating func expression() -> Double? {
            guard var lhs = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" || c == "−" {
                i += 1
                let start = i
                guard var rhs = term() else { return nil }
                if endsWithPercent(from: start) { rhs *= lhs }
                lhs = c == "+" ? lhs + rhs : lhs - rhs
                didCompute = true
            }
            return lhs
        }

        func endsWithPercent(from start: Int) -> Bool {
            var j = i - 1
            while j >= start, chars[j].isWhitespace { j -= 1 }
            return j >= start && chars[j] == "%"
        }

        mutating func term() -> Double? {
            guard var lhs = unary() else { return nil }
            while true {
                guard let c = peek() else { return lhs }
                if c == "*" || c == "×" || c == "x" && nextIsOperand(after: i + 1) || c == "/" || c == "÷" {
                    i += 1
                    guard let rhs = unary() else { return nil }
                    lhs = (c == "/" || c == "÷") ? lhs / rhs : lhs * rhs
                } else if matchWord("of") || matchWord("mod") {
                    let isMod = chars[i - 1] == "d"
                    guard let rhs = unary() else { return nil }
                    lhs = isMod ? lhs.truncatingRemainder(dividingBy: rhs) : lhs * rhs
                } else if c == "(" || c.isNumber || c.isLetter && !startsWord("of") && !startsWord("mod") || c == "π" {
                    guard let rhs = unary() else { return nil }
                    lhs *= rhs
                } else {
                    return lhs
                }
                didCompute = true
            }
        }

        func nextIsOperand(after j: Int) -> Bool {
            var k = j
            while k < chars.count, chars[k].isWhitespace { k += 1 }
            guard k < chars.count else { return false }
            return chars[k].isNumber || chars[k] == "(" || chars[k] == "."
        }

        mutating func startsWord(_ w: String) -> Bool {
            skipSpaces()
            let wc = Array(w)
            guard i + wc.count <= chars.count, Array(chars[i..<(i + wc.count)]).map({ Character($0.lowercased()) }) == wc else { return false }
            return i + wc.count == chars.count || !chars[i + wc.count].isLetter
        }

        mutating func matchWord(_ w: String) -> Bool {
            guard startsWord(w) else { return false }
            i += w.count
            return true
        }

        mutating func unary() -> Double? {
            if let c = peek(), c == "-" || c == "−" || c == "+" {
                i += 1
                guard let v = unary() else { return nil }
                return c == "+" ? v : -v
            }
            return power()
        }

        mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            if let c = peek(), c == "^" || (c == "*" && i + 1 < chars.count && chars[i + 1] == "*") {
                i += c == "^" ? 1 : 2
                guard let exp = unary() else { return nil }
                didCompute = true
                return pow(base, exp)
            }
            return base
        }

        mutating func postfix() -> Double? {
            guard var v = primary() else { return nil }
            while let c = peek() {
                if c == "%" {
                    v /= 100
                } else if c == "!" {
                    guard v >= 0, v <= 170, v == v.rounded() else { return nil }
                    v = (1...max(1, Int(v))).reduce(1.0) { $0 * Double($1) }
                } else if c == "°" {
                    v *= .pi / 180
                } else {
                    break
                }
                i += 1
                didCompute = true
            }
            return v
        }

        mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                guard let v = expression(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            if c.isNumber || c == "." { return number() }
            if c == "π" { i += 1; didCompute = true; return .pi }
            if c.isLetter { return identifier() }
            return nil
        }

        mutating func number() -> Double? {
            if chars[i] == "0", i + 1 < chars.count, "xXbB".contains(chars[i + 1]) {
                let radix = "xX".contains(chars[i + 1]) ? 16 : 2
                var j = i + 2
                var digits = ""
                while j < chars.count, chars[j].isHexDigit { digits.append(chars[j]); j += 1 }
                guard let v = UInt64(digits, radix: radix) else { return nil }
                i = j
                didCompute = true
                return Double(v)
            }
            var s = ""
            while i < chars.count {
                let c = chars[i]
                if c.isNumber || c == "." {
                    s.append(c)
                    i += 1
                } else if c == ",", isThousandsGroup(at: i) {
                    i += 1
                } else if c == "_" {
                    i += 1
                } else if (c == "e" || c == "E"), i + 1 < chars.count, chars[i + 1].isNumber || ((chars[i + 1] == "-" || chars[i + 1] == "+") && i + 2 < chars.count && chars[i + 2].isNumber) {
                    s.append("e")
                    s.append(chars[i + 1])
                    i += 2
                } else {
                    break
                }
            }
            return Double(s)
        }

        /// A comma followed by exactly three digits, as in 1,000,000.
        func isThousandsGroup(at j: Int) -> Bool {
            guard j + 3 < chars.count else { return false }
            for k in 1...3 where !chars[j + k].isNumber { return false }
            return j + 4 == chars.count || !chars[j + 4].isNumber
        }

        mutating func identifier() -> Double? {
            var name = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber && !name.isEmpty {
                name.append(chars[i])
                i += 1
            }
            let lower = name.lowercased()
            if let k = constants[lower] { didCompute = true; return k }
            if lower == "min" || lower == "max" {
                guard peek() == "(" else { return nil }
                i += 1
                var args: [Double] = []
                repeat {
                    guard let a = expression() else { return nil }
                    args.append(a)
                    if peek() == "," { i += 1 } else { break }
                } while true
                guard peek() == ")", !args.isEmpty else { return nil }
                i += 1
                didCompute = true
                return lower == "min" ? args.min() : args.max()
            }
            guard let f = functions[lower] else { return nil }
            guard let arg = postfix() else { return nil }
            didCompute = true
            return f(arg)
        }

        let constants: [String: Double] = ["pi": .pi, "e": M_E, "tau": 2 * .pi]
        let functions: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "cbrt": { cbrt($0) }, "abs": { abs($0) },
            "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
            "asin": { asin($0) }, "acos": { acos($0) }, "atan": { atan($0) },
            "sinh": { sinh($0) }, "cosh": { cosh($0) }, "tanh": { tanh($0) },
            "ln": { log($0) }, "log": { log10($0) }, "log10": { log10($0) }, "log2": { log2($0) },
            "exp": { exp($0) }, "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
        ]
    }
}
