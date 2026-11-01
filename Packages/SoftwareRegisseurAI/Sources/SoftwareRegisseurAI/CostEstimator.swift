import Foundation

/// User-maintained price for one model. No prices are fetched: no provider API returns
/// money amounts (research §2.4). All values per 1M tokens or per audio minute.
public struct ModelPrice: Sendable, Hashable, Codable {
    public var inputPerMillionTokens: Decimal?
    public var outputPerMillionTokens: Decimal?
    /// Cached input reads; when `nil`, cached tokens are priced at the input rate (upper bound).
    public var cachedInputPerMillionTokens: Decimal?
    public var perAudioMinute: Decimal?

    public init(
        inputPerMillionTokens: Decimal? = nil,
        outputPerMillionTokens: Decimal? = nil,
        cachedInputPerMillionTokens: Decimal? = nil,
        perAudioMinute: Decimal? = nil
    ) {
        self.inputPerMillionTokens = inputPerMillionTokens
        self.outputPerMillionTokens = outputPerMillionTokens
        self.cachedInputPerMillionTokens = cachedInputPerMillionTokens
        self.perAudioMinute = perAudioMinute
    }
}

public struct PriceTable: Sendable, Hashable, Codable {
    public struct Key: Sendable, Hashable, Codable {
        public var provider: AIProviderID
        public var model: String

        public init(provider: AIProviderID, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    public var currencyCode: String
    /// Date the user last checked the prices (shown next to the estimate).
    public var asOf: Date?
    public var entries: [Key: ModelPrice]

    public init(currencyCode: String = "USD", asOf: Date? = nil, entries: [Key: ModelPrice] = [:]) {
        self.currencyCode = currencyCode
        self.asOf = asOf
        self.entries = entries
    }

    /// Empty by default; prices are user-configured.
    public static let empty = PriceTable()

    public func price(provider: AIProviderID, model: String) -> ModelPrice? {
        entries[Key(provider: provider, model: model)]
    }

    public mutating func setPrice(_ price: ModelPrice?, provider: AIProviderID, model: String) {
        entries[Key(provider: provider, model: model)] = price
    }

    // Entries are coded as a flat array so the JSON stays human-editable.
    private struct CodedEntry: Codable {
        var provider: AIProviderID
        var model: String
        var price: ModelPrice
    }

    private enum CodingKeys: String, CodingKey {
        case currencyCode, asOf, entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD"
        asOf = try container.decodeIfPresent(Date.self, forKey: .asOf)
        let coded = try container.decodeIfPresent([CodedEntry].self, forKey: .entries) ?? []
        entries = Dictionary(
            coded.map { (Key(provider: $0.provider, model: $0.model), $0.price) },
            uniquingKeysWith: { _, last in last }
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encodeIfPresent(asOf, forKey: .asOf)
        let coded = entries
            .map { CodedEntry(provider: $0.key.provider, model: $0.key.model, price: $0.value) }
            .sorted { ($0.provider.rawValue, $0.model) < ($1.provider.rawValue, $1.model) }
        try container.encode(coded, forKey: .entries)
    }

    public static func decode(from data: Data) throws -> PriceTable {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PriceTable.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public struct AICostEstimate: Sendable, Hashable {
    public var amount: Decimal
    public var currencyCode: String
    public var priceTableAsOf: Date?
    /// Always true: shown as "geschätzt" (spec H3).
    public let isEstimate = true
    /// Usage parts without a configured price (estimate then covers only the priced parts).
    public var unpricedComponents: [String]

    public static let estimateLabel = String(localized: "geschätzt", bundle: .module)

    public func formatted(locale: Locale = Locale(identifier: "de_DE")) -> String {
        let value = amount.formatted(.currency(code: currencyCode).locale(locale).precision(.fractionLength(2...4)))
        return "\(value) (\(Self.estimateLabel))"
    }
}

public struct CostEstimator: Sendable {
    public var priceTable: PriceTable

    public init(priceTable: PriceTable = .empty) {
        self.priceTable = priceTable
    }

    /// `nil` when no price is configured for the model.
    public func estimate(usage: AIUsage, provider: AIProviderID, model: String) -> AICostEstimate? {
        guard let price = priceTable.price(provider: provider, model: model) else { return nil }
        let million = Decimal(1_000_000)
        var amount = Decimal(0)
        var unpriced: [String] = []

        let cached = max(0, min(usage.cachedInputTokens, usage.inputTokens))
        let uncached = usage.inputTokens - cached
        if usage.inputTokens > 0 {
            if let input = price.inputPerMillionTokens {
                amount += Decimal(uncached) * input / million
                amount += Decimal(cached) * (price.cachedInputPerMillionTokens ?? input) / million
            } else {
                unpriced.append("input")
            }
        }
        if usage.outputTokens > 0 {
            if let output = price.outputPerMillionTokens {
                amount += Decimal(usage.outputTokens) * output / million
            } else {
                unpriced.append("output")
            }
        }
        if let seconds = usage.audioSeconds, seconds > 0 {
            if let perMinute = price.perAudioMinute {
                amount += Decimal(seconds) / 60 * perMinute
            } else {
                unpriced.append("audio")
            }
        }
        return AICostEstimate(
            amount: amount, currencyCode: priceTable.currencyCode, priceTableAsOf: priceTable.asOf,
            unpricedComponents: unpriced
        )
    }
}
