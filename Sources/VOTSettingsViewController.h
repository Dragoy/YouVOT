#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, VOTTranslationState) {
    VOTTranslationStateNoVideo = -1,
    VOTTranslationStateOff,
    VOTTranslationStateLoading,
    VOTTranslationStateOn,
};

@interface VOTSettingsViewController : UITableViewController
// Language of the video that is open right now, shown for transparency (may be nil)
@property (nonatomic, copy) NSString *currentVideoLanguage;
// When set (settings opened from the player), the first row turns the translation
// of the current video on and off. The row is refreshed on VOTTranslationStateDidChangeNotification.
@property (nonatomic, copy) VOTTranslationState (^translationStateProvider)(void);
@property (nonatomic, copy) NSString *(^translationStatusProvider)(void);
@property (nonatomic, copy) void (^translationToggleHandler)(BOOL on);
// Overrides currentVideoLanguage, so the row appears as soon as the language is detected
@property (nonatomic, copy) NSString *(^currentVideoLanguageProvider)(void);
- (void)presentFromViewController:(UIViewController *)presenter;
+ (void)presentFromViewController:(UIViewController *)presenter currentVideoLanguage:(NSString *)language;
@end
