import Foundation

/// Unit conversion on top of Foundation's Measurement API. Supports the same
/// categories and trigger syntax as RustCast: `5 km`, `5 km to mi`,
/// `5 km in miles`, `-12.5 c to f`.
enum UnitConversion {
    struct Result {
        let value: String        // formatted converted value, e.g. "3.10686"
        let targetUnit: String   // e.g. "mi"
        let sourceDescription: String // e.g. "5 km"
    }

    private static let lengthUnits: [String: UnitLength] = [
        "mm": .millimeters, "millimeter": .millimeters, "millimetre": .millimeters,
        "cm": .centimeters, "centimeter": .centimeters, "centimetre": .centimeters,
        "m": .meters, "meter": .meters, "metre": .meters,
        "km": .kilometers, "kilometer": .kilometers, "kilometre": .kilometers,
        "in": .inches, "inch": .inches, "inches": .inches,
        "ft": .feet, "foot": .feet, "feet": .feet,
        "yd": .yards, "yard": .yards, "yards": .yards,
        "mi": .miles, "mile": .miles, "miles": .miles,
    ]
    private static let massUnits: [String: UnitMass] = [
        "mg": .milligrams, "milligram": .milligrams,
        "g": .grams, "gram": .grams, "grams": .grams,
        "kg": .kilograms, "kilogram": .kilograms,
        "oz": .ounces, "ounce": .ounces, "ounces": .ounces,
        "lb": .pounds, "lbs": .pounds, "pound": .pounds, "pounds": .pounds,
    ]
    private static let volumeUnits: [String: UnitVolume] = [
        "ml": .milliliters, "milliliter": .milliliters,
        "l": .liters, "liter": .liters, "litre": .liters,
        "tsp": .teaspoons, "teaspoon": .teaspoons,
        "tbsp": .tablespoons, "tablespoon": .tablespoons,
        "floz": .fluidOunces, "fl-oz": .fluidOunces, "fl_oz": .fluidOunces,
        "cup": .cups, "cups": .cups,
        "pt": .pints, "pint": .pints, "pints": .pints,
        "qt": .quarts, "quart": .quarts, "quarts": .quarts,
        "gal": .gallons, "gallon": .gallons, "gallons": .gallons,
    ]
    private static let temperatureUnits: [String: UnitTemperature] = [
        "c": .celsius, "celsius": .celsius, "centigrade": .celsius,
        "f": .fahrenheit, "fahrenheit": .fahrenheit,
        "k": .kelvin, "kelvin": .kelvin,
    ]

    private enum Category {
        case length(UnitLength)
        case mass(UnitMass)
        case volume(UnitVolume)
        case temperature(UnitTemperature)
    }

    private static func category(for token: String) -> Category? {
        let t = token.lowercased()
        if let u = lengthUnits[t] { return .length(u) }
        if let u = massUnits[t] { return .mass(u) }
        if let u = volumeUnits[t] { return .volume(u) }
        if let u = temperatureUnits[t] { return .temperature(u) }
        return nil
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1e15 { return String(format: "%.0f", value) }
        var out = String(format: "%.6f", value)
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    /// Parse queries like "5 km to mi". Returns one result per requested
    /// target (all sibling units when no target is given).
    static func convert(_ query: String) -> [Result]? {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = trimmed.first, first.isNumber || first == "-" || first == "+" else { return nil }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }

        // number
        guard let value = Double(tokens[0]) else { return nil }

        let unitTokens = Array(tokens.dropFirst())
        if unitTokens.first == "to" || unitTokens.first == "in" { return nil }
        if unitTokens.count >= 2 && (unitTokens[1] == "to" || unitTokens[1] == "in") {
            // "<num> <unit> to <unit>"
            guard unitTokens.count == 3 else { return nil }
            return convert(value: value, from: unitTokens[0], to: unitTokens[2]).map { [$0] }
        }
        if unitTokens.count == 2 {
            return convert(value: value, from: unitTokens[0], to: unitTokens[1]).map { [$0] }
        }
        if unitTokens.count == 1 {
            return convertToSiblings(value: value, from: unitTokens[0])
        }
        return nil
    }

    private static func convert(value: Double, from source: String, to target: String) -> Result? {
        guard let s = category(for: source), let t = category(for: target) else { return nil }
        switch (s, t) {
        case let (.length(su), .length(tu)):
            return make(value, source, target) { Measurement(value: value, unit: su).converted(to: tu).value }
        case let (.mass(su), .mass(tu)):
            return make(value, source, target) { Measurement(value: value, unit: su).converted(to: tu).value }
        case let (.volume(su), .volume(tu)):
            return make(value, source, target) { Measurement(value: value, unit: su).converted(to: tu).value }
        case let (.temperature(su), .temperature(tu)):
            return make(value, source, target) { Measurement(value: value, unit: su).converted(to: tu).value }
        default:
            return nil
        }
    }

    private static func convertToSiblings(value: Double, from source: String) -> [Result]? {
        switch category(for: source) {
        case .length(let u)?:
            return lengthUnits.filter { $0.key != source && $0.key.count <= 4 }.sorted { $0.key < $1.key }
                .compactMap { key, target in
                    make(value, source, key) { Measurement(value: value, unit: u).converted(to: target).value }
                }
        case .mass(let u)?:
            return massUnits.filter { $0.key != source && $0.key.count <= 4 }.sorted { $0.key < $1.key }
                .compactMap { key, target in
                    make(value, source, key) { Measurement(value: value, unit: u).converted(to: target).value }
                }
        case .volume(let u)?:
            return volumeUnits.filter { $0.key != source && $0.key.count <= 4 }.sorted { $0.key < $1.key }
                .compactMap { key, target in
                    make(value, source, key) { Measurement(value: value, unit: u).converted(to: target).value }
                }
        case .temperature(let u)?:
            return temperatureUnits.filter { $0.key != source }.sorted { $0.key < $1.key }
                .compactMap { key, target in
                    make(value, source, key) { Measurement(value: value, unit: u).converted(to: target).value }
                }
        case nil:
            return nil
        }
    }

    private static func make(_ value: Double, _ source: String, _ target: String,
                             _ compute: () -> Double) -> Result? {
        let converted = compute()
        guard converted.isFinite else { return nil }
        return Result(value: format(converted), targetUnit: target,
                      sourceDescription: "\(format(value)) \(source)")
    }
}
