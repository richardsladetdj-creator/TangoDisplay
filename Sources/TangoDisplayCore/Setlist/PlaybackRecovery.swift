import Foundation

package enum PlaybackFailure: LocalizedError {
    case outputUnavailable
    case track(String)

    package var errorDescription: String? {
        switch self {
        case .outputUnavailable: return "The audio output is unavailable."
        case .track(let reason): return reason
        }
    }
}

package enum PlaybackRecovery {
    package enum Request {
        case start(SetlistEntry?, bypassAutoGap: Bool)
        case recover(after: UUID, error: Error)
    }

    package enum Outcome {
        case started(SetlistEntry)
        case waitingForOutput(SetlistEntry)
        case exhausted
    }

    package static func run(
        _ request: Request,
        nextAfter: (UUID) -> SetlistEntry?,
        attempt: (SetlistEntry, Bool) throws -> Void,
        didFail: (UUID, Error) -> Void
    ) -> Outcome {
        var candidate: SetlistEntry?
        var bypassAutoGap: Bool
        switch request {
        case .start(let entry, let bypass):
            candidate = entry
            bypassAutoGap = bypass
        case .recover(let id, let error):
            didFail(id, error)
            candidate = nextAfter(id)
            bypassAutoGap = true
        }

        while let entry = candidate {
            do {
                try attempt(entry, bypassAutoGap)
                return .started(entry)
            } catch PlaybackFailure.outputUnavailable {
                return .waitingForOutput(entry)
            } catch {
                didFail(entry.id, error)
                candidate = nextAfter(entry.id)
                bypassAutoGap = true
            }
        }
        return .exhausted
    }
}
