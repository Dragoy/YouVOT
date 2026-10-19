#import "VOTLog.h"

static const NSUInteger kVOTLogLimit = 400;

static NSMutableArray<NSString *> *LogLines(void) {
    static NSMutableArray *lines;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lines = [NSMutableArray array];
    });
    return lines;
}

void VOTLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"[YouVOT] %@", message);

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss";
    });
    NSMutableArray *lines = LogLines();
    @synchronized (lines) {
        [lines addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:[NSDate date]], message]];
        if (lines.count > kVOTLogLimit) [lines removeObjectsInRange:NSMakeRange(0, lines.count - kVOTLogLimit)];
    }
}

NSString *VOTLogText(void) {
    NSMutableArray *lines = LogLines();
    @synchronized (lines) {
        return [lines componentsJoinedByString:@"\n"];
    }
}

void VOTLogClear(void) {
    NSMutableArray *lines = LogLines();
    @synchronized (lines) {
        [lines removeAllObjects];
    }
}
