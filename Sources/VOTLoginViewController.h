#import <UIKit/UIKit.h>

// Signs in to Yandex with the extension's OAuth flow and stores the token (VOTSetAccountToken)
@interface VOTLoginViewController : UIViewController
@property (nonatomic, copy) void (^completion)(BOOL signedIn);
@end
