#import <Foundation/Foundation.h>

// Small in-memory log of what the translation pipeline did, shown in the settings
// so a failed translation can be diagnosed on the device. Thread-safe.
FOUNDATION_EXPORT void VOTLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *VOTLogText(void);
FOUNDATION_EXPORT void VOTLogClear(void);
