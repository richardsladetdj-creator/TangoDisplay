import AudioToolbox
import AVFoundation
import Foundation
import TangoDisplayObjC

package enum EmbeddedTagReader {
    package static func read(from url: URL) async -> [String: String] {
        let metadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
        return await read(from: url, metadata: metadata)
    }

    package static func read(from url: URL, metadata: [AVMetadataItem]) async -> [String: String] {
        // Treat empty strings the same as missing: return nil so the ?? chain keeps searching.
        func string(for id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first else { return nil }
            guard let val = try? await item.load(.stringValue), !val.isEmpty else { return nil }
            return val
        }

        // Raw-key scan for formats (FLAC/Vorbis) where AVFoundation has no typed identifier,
        // also catches stray tags where identifier mapping fails.
        func string(forRawKey rawKey: String) async -> String? {
            guard let item = metadata.first(where: { ($0.key as? String)?.lowercased() == rawKey.lowercased() }) else { return nil }
            guard let val = try? await item.load(.stringValue), !val.isEmpty else { return nil }
            return val
        }

        // Old iTunes (v4.x era) M4A files store itsk keys as packed NSNumber 4-char codes rather
        // than NSString, so filteredByIdentifier misses them. Match by packed int32 value instead.
        // Uses unicodeScalars (not utf8) so that multi-byte UTF-8 chars like © (U+00A9 = 0xA9)
        // are treated as a single byte — matching the 4-char atom code convention.
        func string(forITunesAtom atomCode: String) async -> String? {
            let scalars = Array(atomCode.unicodeScalars)
            guard scalars.count == 4 else { return nil }
            let bytes = scalars.map { UInt8($0.value & 0xFF) }
            let packed = Int32(bitPattern: (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
            guard let item = metadata.first(where: { ($0.key as? NSNumber)?.int32Value == packed && $0.keySpace == .iTunes }) else { return nil }
            guard let val = try? await item.load(.stringValue), !val.isEmpty else { return nil }
            return val
        }

        // Skips Apple machine-generated COMM frames (iTunNORM, iTunSMPB, iTunPGAP, etc.) that
        // store binary data as hex strings — AVFoundation returns all COMM frames and .first may
        // land on one of these instead of the human-readable comment.
        func humanReadableComment() async -> String? {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .id3MetadataComments)
            for item in items {
                let info = (try? await item.load(.extraAttributes))?[AVMetadataExtraAttributeKey.info] as? String ?? ""
                guard !info.hasPrefix("iTun") else { continue }
                if let val = try? await item.load(.stringValue), !val.isEmpty { return val }
            }
            return nil
        }

        // Resolves raw ID3 TCON values that encode genre as a number rather than text.
        // Handles "(N)", "(N)Text", and plain "N" forms; passes real text through unchanged.
        func resolveID3Genre(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            if raw.hasPrefix("("), let close = raw.firstIndex(of: ")") {
                let numStr = String(raw[raw.index(after: raw.startIndex)..<close])
                let text = String(raw[raw.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
                if let n = Int(numStr), n >= 0, n < id3GenreNames.count { return id3GenreNames[n] }
            }
            if let n = Int(raw), n >= 0, n < id3GenreNames.count { return id3GenreNames[n] }
            return raw
        }

        // M4A predefined genre: `gnre` atom stores an integer (ID3v1 index + 1).
        // Music.app uses this when the user picks from its genre dropdown rather than typing.
        func predefinedGenreName() async -> String? {
            guard let item = AVMetadataItem.metadataItems(
                from: metadata, filteredByIdentifier: .iTunesMetadataPredefinedGenre).first
            else { return nil }
            if let str = try? await item.load(.stringValue), !str.isEmpty { return str }
            guard let n = (try? await item.load(.numberValue))?.intValue, n > 0, n <= id3GenreNames.count
            else { return nil }
            return id3GenreNames[n - 1]
        }

        // Some containers expose only part of their metadata through AVFoundation.
        let embedded = TDReadTags(url.path) ?? [:]
        let title = await string(for: .commonIdentifierTitle)
        let artist = await string(for: .commonIdentifierArtist)
        let genreID3 = resolveID3Genre(await string(for: .id3MetadataContentType))
        let genreiTunes = await string(for: .iTunesMetadataUserGenre)
        let genrePredefined = await predefinedGenreName()
        let genreVorbis = await string(forRawKey: "genre")
        let genreRawTcon = resolveID3Genre(await string(forRawKey: "tcon"))
        let genre = genreID3 ?? genreiTunes ?? genrePredefined ?? genreVorbis ?? genreRawTcon
            ?? resolveID3Genre(embedded["GENRE"]) ?? genreFromAudioToolbox(url)
        let yearID3 = (await string(for: .id3MetadataYear)).flatMap(Int.init)
        let yeariTunes = (await string(for: .iTunesMetadataReleaseDate)).flatMap { Int($0.prefix(4)) }
        let yearRawID3 = (await string(forRawKey: "tdrc")).flatMap { Int($0.prefix(4)) }
        let year = yearID3 ?? yeariTunes ?? yearRawID3
            ?? embedded["DATE"].flatMap { Int($0.prefix(4)) } ?? yearFromAudioToolbox(url)
        let commentID3 = await humanReadableComment()
        let commentiTunes = await string(for: .iTunesMetadataUserComment)
        let albumArtistID3 = await string(for: .id3MetadataBand)
        let albumArtistiTunes = await string(for: .iTunesMetadataAlbumArtist)
        let albumArtistOldiTunes = await string(forITunesAtom: "aART")
        let groupingID3 = await string(for: .id3MetadataContentGroupDescription)
        let groupingiTunes = await string(for: .iTunesMetadataGrouping)
        let groupingOldiTunes = await string(forITunesAtom: "©grp")
        let groupingVorbis = await string(forRawKey: "grouping")
        let groupingRawID3 = await string(forRawKey: "tit1")
        // Prefer modern ID3 grouping (GRP1) over the legacy TIT1 work/grouping field.
        let grouping = embedded["GROUPING"] ?? groupingiTunes ?? groupingOldiTunes ?? groupingVorbis
            ?? groupingID3 ?? groupingRawID3 ?? embedded["WORK"]

        let fields: [String: String?] = [
            "TITLE": title ?? embedded["TITLE"],
            "ARTIST": artist ?? embedded["ARTIST"],
            "GENRE": genre,
            "DATE": year.map(String.init),
            "COMMENT": commentID3 ?? commentiTunes ?? embedded["COMMENT"],
            "ALBUMARTIST": albumArtistID3 ?? albumArtistiTunes ?? albumArtistOldiTunes ?? embedded["ALBUMARTIST"],
            "GROUPING": grouping,
        ]
        return fields.compactMapValues { $0 }.filter { !$0.value.isEmpty }
    }

    private static func genreFromAudioToolbox(_ url: URL) -> String? {
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
              let af = audioFile else { return nil }
        defer { AudioFileClose(af) }

        var dataSize = UInt32(MemoryLayout<CFDictionary>.size)
        var cfDictRef: Unmanaged<CFDictionary>? = nil
        guard AudioFileGetProperty(af, kAudioFilePropertyInfoDictionary, &dataSize, &cfDictRef) == noErr,
              let info = cfDictRef?.takeRetainedValue() as? [String: Any],
              let genre = info[kAFInfoDictionary_Genre as String] as? String,
              !genre.isEmpty else { return nil }
        return genre
    }

    private static func yearFromAudioToolbox(_ url: URL) -> Int? {
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
              let af = audioFile else { return nil }
        defer { AudioFileClose(af) }

        var dataSize = UInt32(MemoryLayout<CFDictionary>.size)
        var cfDictRef: Unmanaged<CFDictionary>? = nil
        guard AudioFileGetProperty(af, kAudioFilePropertyInfoDictionary, &dataSize, &cfDictRef) == noErr,
              let info = cfDictRef?.takeRetainedValue() as? [String: Any] else { return nil }
        if let s = info[kAFInfoDictionary_Year as String] as? String, !s.isEmpty,
           let y = Int(s.prefix(4)) { return y }
        if let s = info[kAFInfoDictionary_RecordedDate as String] as? String, !s.isEmpty,
           let y = Int(s.prefix(4)) { return y }
        return nil
    }
}

// Standard iTunes/ID3v1/Winamp genre list (192 entries).
// The M4A `gnre` atom stores (index + 1), so gnre=114 → index 113 → "Tango".
private let id3GenreNames: [String] = [
    "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge",
    "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B",
    "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska",
    "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop",
    "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental",
    "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock",
    "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop",
    "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial",
    "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy",
    "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
    "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
    "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro",
    "Musical", "Rock & Roll", "Hard Rock",
    // Winamp extensions (80+)
    "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop",
    "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock",
    "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock",
    "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech",
    "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass",
    "Primus", "Porn Groove", "Satire", "Slow Jam", "Club",
    "Tango",         // index 113
    "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
    "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House", "Dance Hall",
    "Goa", "Drum & Bass", "Club-House", "Hardcore", "Terror", "Indie",
    "BritPop", "Negerpunk", "Polsk Punk", "Beat", "Christian Gangsta Rap",
    "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian",
    "Christian Rock", "Merengue", "Salsa", "Thrash Metal", "Anime", "JPop",
    "Synthpop",
]
