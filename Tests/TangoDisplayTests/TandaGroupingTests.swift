import Foundation
import TangoDisplayCore

func runTandaGroupingTests() {
    func item(_ artist: String, _ genre: String, year: Int? = nil, cortina: Bool = false) -> TandaGrouping.Item {
        TandaGrouping.Item(id: UUID(),
                           track: Track(title: "t", artist: artist, genre: genre,
                                        persistentID: UUID().uuidString, year: year),
                           isCortina: cortina)
    }

    suite("TandaGrouping — positions") {
        test("cortinas split tandas and get no info") {
            let items = [item("D'Arienzo", "Tango"), item("D'Arienzo", "Tango"),
                         item("X", "Cortina", cortina: true),
                         item("Di Sarli", "Vals")]
            let g = TandaGrouping.group(items)
            try expectEqual(g[items[0].id]?.position, 1)
            try expectEqual(g[items[1].id]?.position, 2)
            try expectEqual(g[items[1].id]?.total, 2)
            try expect(g[items[1].id]?.isLast == true)
            try expectNil(g[items[2].id])
            try expectEqual(g[items[3].id]?.total, 1)
            try expectEqual(g[items[3].id]?.summary.firstID, items[3].id)
        }
        test("leading cortinas don't create empty tandas") {
            let items = [item("X", "Cortina", cortina: true), item("X", "Cortina", cortina: true),
                         item("Pugliese", "Tango")]
            let g = TandaGrouping.group(items)
            try expectEqual(g.count, 1)
        }
    }

    suite("TandaGrouping — mixed detection") {
        test("same orchestra with different singers is not mixed") {
            let items = [item("Juan D'Arienzo / Héctor Mauré", "Tango"),
                         item("Juan D'Arienzo / Alberto Echagüe", "Tango")]
            let s = TandaGrouping.group(items)[items[0].id]!.summary
            try expect(!s.mixedOrchestra)
            try expectEqual(s.orchestra, "Juan D'Arienzo")
        }
        test("case and accents ignored") {
            let items = [item("Ángel D'Agostino", "tango"), item("angel d'agostino", "Tango")]
            let s = TandaGrouping.group(items)[items[0].id]!.summary
            try expect(!s.mixedOrchestra)
            try expect(!s.mixedGenre)
        }
        test("different orchestras are mixed, no orchestra name") {
            let items = [item("Di Sarli", "Tango"), item("Troilo", "Tango")]
            let s = TandaGrouping.group(items)[items[0].id]!.summary
            try expect(s.mixedOrchestra)
            try expectNil(s.orchestra)
        }
        test("mixed genre and decade flagged") {
            let items = [item("Canaro", "Milonga", year: 1938), item("Canaro", "Tango", year: 1951),
                         item("Canaro", "Milonga", year: 1939)]
            let s = TandaGrouping.group(items)[items[0].id]!.summary
            try expect(s.mixedGenre)
            try expect(s.mixedDecade)
            try expectEqual(s.genre, "Milonga")
        }
        test("missing tags don't count as mixed") {
            let items = [item("Biagi", "Tango", year: 1941), item("", "", year: nil)]
            let s = TandaGrouping.group(items)[items[0].id]!.summary
            try expect(!s.isMixed)
        }
    }
}
