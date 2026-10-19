#import <Foundation/Foundation.h>

// Minimal protobuf wire-format writer/reader, enough for the Yandex
// video-translation API (see FOSWLY/vot.js packages/shared/src/protos/yandex.proto).

@interface VOTPBWriter : NSObject
@property (nonatomic, readonly) NSData *data;
- (void)writeVarint:(uint64_t)value field:(uint32_t)field;
- (void)writeBool:(BOOL)value field:(uint32_t)field;
- (void)writeDouble:(double)value field:(uint32_t)field;
- (void)writeString:(NSString *)value field:(uint32_t)field;
- (void)writeBytes:(NSData *)value field:(uint32_t)field;
- (void)writeMessage:(VOTPBWriter *)message field:(uint32_t)field;
@end

// Decoded message: field number -> array of values.
// varint -> NSNumber (unsigned long long), fixed64 -> NSNumber (double),
// fixed32 -> NSNumber (float), length-delimited -> NSData.
typedef NSDictionary<NSNumber *, NSArray *> VOTPBMessage;

FOUNDATION_EXPORT VOTPBMessage *VOTPBDecode(NSData *data);
FOUNDATION_EXPORT NSString *VOTPBString(VOTPBMessage *message, uint32_t field);
FOUNDATION_EXPORT int64_t VOTPBInt(VOTPBMessage *message, uint32_t field, int64_t fallback);
FOUNDATION_EXPORT double VOTPBDouble(VOTPBMessage *message, uint32_t field, double fallback);
FOUNDATION_EXPORT NSArray<NSString *> *VOTPBStrings(VOTPBMessage *message, uint32_t field);
