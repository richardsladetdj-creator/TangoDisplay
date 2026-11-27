//
//  TDTagWriter.h
//  Writes text tags into an audio file through TagLib (MPL-1.1), via the
//  sbooth/CXXTagLib SwiftPM package. Reads stay on AVFoundation.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Writes `tags` into the file at `path`, in place. Keys are TagLib property names —
/// TITLE, ARTIST, GENRE, DATE, COMMENT, ALBUMARTIST, GROUPING. An empty value removes
/// the field; keys absent from `tags` are left as they are.
/// Returns NO with *outError set when the file can't be opened, has no taggable
/// container, or the save fails. After saving and reopening, outFieldIssues
/// contains a reason for each requested field that did not round-trip.
/// Callers wanting atomicity write to a copy first.
BOOL TDWriteTags(NSString *path,
                 NSDictionary<NSString *, NSString *> *tags,
                 NSDictionary<NSString *, NSString *> * _Nullable * _Nullable outFieldIssues,
                 NSString * _Nullable * _Nullable outError);

/// Returns the first embedded value of each TagLib property, or nil for an unreadable file.
NSDictionary<NSString *, NSString *> * _Nullable TDReadTags(NSString *path);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
