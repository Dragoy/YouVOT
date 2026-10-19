#import "VOTProtobuf.h"

typedef NS_ENUM(uint32_t, VOTPBWireType) {
    VOTPBWireVarint = 0,
    VOTPBWireFixed64 = 1,
    VOTPBWireLengthDelimited = 2,
    VOTPBWireFixed32 = 5,
};

@implementation VOTPBWriter {
    NSMutableData *_buffer;
}

- (instancetype)init {
    self = [super init];
    if (self) _buffer = [NSMutableData data];
    return self;
}

- (NSData *)data {
    return [_buffer copy];
}

- (void)appendRawVarint:(uint64_t)value {
    uint8_t bytes[10];
    NSUInteger length = 0;
    do {
        uint8_t byte = value & 0x7F;
        value >>= 7;
        if (value) byte |= 0x80;
        bytes[length++] = byte;
    } while (value);
    [_buffer appendBytes:bytes length:length];
}

- (void)appendTag:(uint32_t)field wireType:(VOTPBWireType)wireType {
    [self appendRawVarint:((uint64_t)field << 3) | wireType];
}

- (void)writeVarint:(uint64_t)value field:(uint32_t)field {
    [self appendTag:field wireType:VOTPBWireVarint];
    [self appendRawVarint:value];
}

- (void)writeBool:(BOOL)value field:(uint32_t)field {
    [self writeVarint:value ? 1 : 0 field:field];
}

- (void)writeDouble:(double)value field:(uint32_t)field {
    [self appendTag:field wireType:VOTPBWireFixed64];
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    bits = CFSwapInt64HostToLittle(bits);
    [_buffer appendBytes:&bits length:sizeof(bits)];
}

- (void)writeBytes:(NSData *)value field:(uint32_t)field {
    [self appendTag:field wireType:VOTPBWireLengthDelimited];
    [self appendRawVarint:value.length];
    [_buffer appendData:value ?: [NSData data]];
}

- (void)writeString:(NSString *)value field:(uint32_t)field {
    [self writeBytes:[value ?: @"" dataUsingEncoding:NSUTF8StringEncoding] field:field];
}

- (void)writeMessage:(VOTPBWriter *)message field:(uint32_t)field {
    [self writeBytes:message.data field:field];
}

@end

static BOOL VOTPBReadVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *pos, uint64_t *out) {
    uint64_t result = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (*pos >= length) return NO;
        uint8_t byte = bytes[(*pos)++];
        result |= (uint64_t)(byte & 0x7F) << shift;
        if (!(byte & 0x80)) {
            *out = result;
            return YES;
        }
    }
    return NO;
}

VOTPBMessage *VOTPBDecode(NSData *data) {
    NSMutableDictionary<NSNumber *, NSMutableArray *> *result = [NSMutableDictionary dictionary];
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length, pos = 0;
    while (pos < length) {
        uint64_t tag;
        if (!VOTPBReadVarint(bytes, length, &pos, &tag)) break;
        uint32_t field = (uint32_t)(tag >> 3);
        id value = nil;
        switch (tag & 7) {
            case VOTPBWireVarint: {
                uint64_t v;
                if (!VOTPBReadVarint(bytes, length, &pos, &v)) return result;
                value = @(v);
                break;
            }
            case VOTPBWireFixed64: {
                if (pos + 8 > length) return result;
                uint64_t bits;
                memcpy(&bits, bytes + pos, 8);
                bits = CFSwapInt64LittleToHost(bits);
                double d;
                memcpy(&d, &bits, 8);
                value = @(d);
                pos += 8;
                break;
            }
            case VOTPBWireLengthDelimited: {
                uint64_t len;
                if (!VOTPBReadVarint(bytes, length, &pos, &len) || pos + len > length) return result;
                value = [data subdataWithRange:NSMakeRange(pos, (NSUInteger)len)];
                pos += (NSUInteger)len;
                break;
            }
            case VOTPBWireFixed32: {
                if (pos + 4 > length) return result;
                uint32_t bits;
                memcpy(&bits, bytes + pos, 4);
                bits = CFSwapInt32LittleToHost(bits);
                float f;
                memcpy(&f, &bits, 4);
                value = @(f);
                pos += 4;
                break;
            }
            default:
                return result;
        }
        NSMutableArray *values = result[@(field)];
        if (!values) result[@(field)] = values = [NSMutableArray array];
        [values addObject:value];
    }
    return result;
}

NSString *VOTPBString(VOTPBMessage *message, uint32_t field) {
    id value = message[@(field)].lastObject;
    if (![value isKindOfClass:[NSData class]]) return nil;
    return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
}

NSArray<NSString *> *VOTPBStrings(VOTPBMessage *message, uint32_t field) {
    NSMutableArray *strings = [NSMutableArray array];
    for (id value in message[@(field)]) {
        if (![value isKindOfClass:[NSData class]]) continue;
        NSString *string = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
        if (string) [strings addObject:string];
    }
    return strings;
}

int64_t VOTPBInt(VOTPBMessage *message, uint32_t field, int64_t fallback) {
    id value = message[@(field)].lastObject;
    if (![value isKindOfClass:[NSNumber class]]) return fallback;
    // int32 fields with negative values are sent as 10-byte two's complement varints
    return (int64_t)[value unsignedLongLongValue];
}

double VOTPBDouble(VOTPBMessage *message, uint32_t field, double fallback) {
    id value = message[@(field)].lastObject;
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}
