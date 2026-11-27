#import "include/TDTagWriter.h"

#include <taglib/fileref.h>
#include <taglib/tpropertymap.h>
#include <taglib/mpegfile.h>
#include <taglib/aifffile.h>
#include <taglib/wavfile.h>

static TagLib::String TDString(NSString *s) {
    return TagLib::String(s.UTF8String, TagLib::String::UTF8);
}

NSDictionary<NSString *, NSString *> *TDReadTags(NSString *path) {
    TagLib::FileRef ref(path.fileSystemRepresentation, false);
    if (ref.isNull()) return nil;
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    const auto props = ref.file()->properties();
    for (const auto &property : props) {
        if (property.second.isEmpty()) continue;
        NSString *key = [NSString stringWithUTF8String:property.first.to8Bit(true).c_str()];
        NSString *value = [NSString stringWithUTF8String:property.second.front().to8Bit(true).c_str()];
        if (key && value) result[key] = value;
    }
    return result;
}

BOOL TDWriteTags(NSString *path,
                 NSDictionary<NSString *, NSString *> *tags,
                 NSDictionary<NSString *, NSString *> **outFieldIssues,
                 NSString **outError) {
    NSMutableDictionary<NSString *, NSString *> *issues = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *requested = [tags mutableCopy];
    TagLib::PropertyMap unsupported;
    bool mirrorGrouping = false;
    {
        TagLib::FileRef ref(path.fileSystemRepresentation, false);
        if (ref.isNull()) {
            if (outError) *outError = @"File type not supported for tag writing";
            return NO;
        }

        TagLib::File *file = ref.file();
        const bool carriesID3v2 = dynamic_cast<TagLib::MPEG::File *>(file)
                             || dynamic_cast<TagLib::RIFF::AIFF::File *>(file)
                             || dynamic_cast<TagLib::RIFF::WAV::File *>(file);
        TagLib::PropertyMap props = file->properties();

        if (carriesID3v2 && tags[@"GROUPING"] && !tags[@"WORK"]) {
            // GRP1 stores grouping. TIT1 can be a legacy grouping mirror or an independent
            // work title. Only replace or clear TIT1 when its provenance is unambiguous.
            const auto work = props.find("WORK");
            const auto grouping = props.find("GROUPING");
            mirrorGrouping = work == props.end() || work->second.isEmpty()
                || (grouping != props.end() && work->second == grouping->second);
            if (!mirrorGrouping && [tags[@"GROUPING"] length] == 0) {
                issues[@"GROUPING"] = @"The ID3 work title was preserved because it may also be read as legacy grouping.";
                [requested removeObjectForKey:@"GROUPING"];
            }
        }

        for (NSString *key in requested) {
            NSString *value = requested[key];
            const auto property = TDString(key);
            if (value.length == 0) props.erase(property);
            else props.replace(property, TagLib::StringList(TDString(value)));

            if (mirrorGrouping && [key isEqualToString:@"GROUPING"]) {
                if (value.length == 0) props.erase("WORK");
                else props.replace("WORK", TagLib::StringList(TDString(value)));
            }
        }

        if (requested.count) {
            unsupported = file->setProperties(props);
            if (!file->save()) {
                if (outError) *outError = @"Could not save tags to the temporary audio file";
                return NO;
            }
        }
    }

    if (requested.count) {
        NSDictionary *actual = TDReadTags(path);
        if (!actual) {
            if (outError) *outError = @"Could not reopen the audio file to verify the saved tags";
            return NO;
        }
        for (NSString *key in requested) {
            NSString *expected = requested[key];
            if ([(actual[key] ?: @"") isEqualToString:expected]) continue;
            issues[key] = unsupported.contains(TDString(key))
                ? @"This format does not support the requested value."
                : @"The requested value could not be verified after saving.";
        }
    }

    if (outFieldIssues) *outFieldIssues = issues;
    return YES;
}
