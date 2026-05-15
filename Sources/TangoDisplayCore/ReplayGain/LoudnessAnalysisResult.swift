import Foundation

public struct LoudnessAnalysisCacheKey: Codable, Hashable {
    public let filePath: String
    public let fileSize: Int64
    public let modifiedDate: Date

    public init(filePath: String, fileSize: Int64, modifiedDate: Date) {
        self.filePath = filePath
        self.fileSize = fileSize
        self.modifiedDate = modifiedDate
    }
}

public struct LoudnessAnalysisResult: Codable, Equatable {
    public let filePath: String
    public let fileSize: Int64
    public let modifiedDate: Date
    public let duration: TimeInterval
    public let integratedLoudnessLufs: Double
    public let calculatedReplayGainDb: Double   // = targetLoudnessLufs - integratedLoudnessLufs
    public let targetLoudnessLufs: Double
    public let samplePeak: Double?
    public let truePeak: Double?
    public let analysedAt: Date

    public init(filePath: String, fileSize: Int64, modifiedDate: Date, duration: TimeInterval,
                integratedLoudnessLufs: Double, calculatedReplayGainDb: Double,
                targetLoudnessLufs: Double, samplePeak: Double?, truePeak: Double?,
                analysedAt: Date) {
        self.filePath = filePath
        self.fileSize = fileSize
        self.modifiedDate = modifiedDate
        self.duration = duration
        self.integratedLoudnessLufs = integratedLoudnessLufs
        self.calculatedReplayGainDb = calculatedReplayGainDb
        self.targetLoudnessLufs = targetLoudnessLufs
        self.samplePeak = samplePeak
        self.truePeak = truePeak
        self.analysedAt = analysedAt
    }

    public var cacheKey: LoudnessAnalysisCacheKey {
        LoudnessAnalysisCacheKey(filePath: filePath, fileSize: fileSize, modifiedDate: modifiedDate)
    }
}
