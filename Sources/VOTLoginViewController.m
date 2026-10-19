#import "VOTLoginViewController.h"
#import "VOTLog.h"
#import "VOTSettings.h"
#import <WebKit/WebKit.h>

// Same endpoints as authLoginUrl in the extension's config: the server redirects to
// oauth.yandex.ru, which comes back to /auth/callback#access_token=...&expires_in=...
static NSString *const kVOTAuthLoginURL = @"https://rust-server-531j.onrender.com/v1/auth/handle";
static NSString *const kVOTAuthCallbackHost = @"rust-server-531j.onrender.com";
static NSString *const kVOTAuthCallbackPath = @"/auth/callback";

@interface VOTLoginViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) BOOL finished;
@end

@implementation VOTLoginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = VOTLocalized(@"SIGN_IN_TITLE");
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // Keep the Yandex login cookies away from anything else in the app
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    // The auth server sleeps when idle and may take a while to answer the first request
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kVOTAuthLoginURL]]];
}

- (void)cancel {
    [self finish:NO];
}

- (void)finish:(BOOL)signedIn {
    if (self.finished) return;
    self.finished = YES;
    void (^completion)(BOOL) = self.completion;
    [self.navigationController popViewControllerAnimated:YES];
    if (self.presentingViewController && self.navigationController.viewControllers.firstObject == self)
        [self dismissViewControllerAnimated:YES completion:nil];
    if (completion) completion(signedIn);
}

- (BOOL)handleCallbackURL:(NSURL *)url {
    if (![url.host isEqualToString:kVOTAuthCallbackHost] || ![url.path hasPrefix:kVOTAuthCallbackPath]) return NO;
    NSURLComponents *fragment = [NSURLComponents new];
    fragment.query = url.fragment;
    NSString *token = nil, *expiresIn = nil;
    for (NSURLQueryItem *item in fragment.queryItems) {
        if ([item.name isEqualToString:@"access_token"]) token = item.value;
        if ([item.name isEqualToString:@"expires_in"]) expiresIn = item.value;
    }
    if (token.length && expiresIn.doubleValue > 0) {
        VOTSetAccountToken(token, expiresIn.doubleValue);
        VOTLog(@"signed in to Yandex, token valid for %.0f days", expiresIn.doubleValue / 86400);
        [self finish:YES];
    } else {
        VOTLog(@"sign-in callback without a token");
        [self finish:NO];
    }
    return YES;
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if ([self handleCallbackURL:navigationAction.request.URL]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
    // A fragment-only change does not always start a new navigation
    [self handleCallbackURL:webView.URL];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self.spinner stopAnimating];
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    VOTLog(@"sign-in page failed to load: %@", error.localizedDescription);
}

@end
