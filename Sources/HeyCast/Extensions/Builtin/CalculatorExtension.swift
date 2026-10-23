import Foundation

struct CalculatorExtension: HeyCastExtension {
    let id = "calculator"
    let title = "Calculator"
    var providers: [ResultProvider] { [UnitProvider(), MathProvider()] }

    struct UnitProvider: ResultProvider {
        let phase = ResultPhase.instantAnswer

        func results(for query: String, ctx: ExtensionContext) -> [ResultItem] {
            guard let conversions = UnitConversion.convert(query) else { return [] }
            return conversions.prefix(8).map { conversion in
                ResultItem(id: "unit-\(query)-\(conversion.targetUnit)",
                           title: "\(conversion.value) \(conversion.targetUnit)",
                           subtitle: conversion.sourceDescription,
                           icon: .symbol("ruler"),
                           action: .copyText("\(conversion.value) \(conversion.targetUnit)"))
            }
        }
    }

    struct MathProvider: ResultProvider {
        let phase = ResultPhase.instantAnswer

        func results(for query: String, ctx: ExtensionContext) -> [ResultItem] {
            guard let value = Calculator.evaluate(query) else { return [] }
            return [ResultItem(id: "calc-\(query)",
                               title: Calculator.format(value),
                               subtitle: query,
                               icon: .symbol("equal.square"),
                               action: .copyText(Calculator.format(value)))]
        }
    }
}
