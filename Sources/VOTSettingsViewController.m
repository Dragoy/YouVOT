#import "VOTSettingsViewController.h"
#import "VOTLanguage.h"
#import "VOTSettings.h"
#import "VOTLog.h"
#import "VOTLoginViewController.h"

#pragma mark - Option list

@interface VOTOptionsViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSString *> *values;
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *selected;
@property (nonatomic, assign) BOOL multiple;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) void (^onChange)(NSArray<NSString *> *selected);
@end

@implementation VOTOptionsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.values.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"option"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"option"];
    cell.textLabel.text = self.titles[indexPath.row];
    cell.accessoryType = [self.selected containsObject:self.values[indexPath.row]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *value = self.values[indexPath.row];
    if (self.multiple) {
        if ([self.selected containsObject:value]) [self.selected removeObject:value];
        else [self.selected addObject:value];
    } else {
        [self.selected removeAllObjects];
        [self.selected addObject:value];
    }
    [tableView reloadData];
    if (self.onChange) self.onChange(self.selected.array);
    if (!self.multiple) [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Slider cell

@interface VOTSliderCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, copy) void (^onChange)(float value);
@end

@implementation VOTSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _titleLabel = [UILabel new];
        _valueLabel = [UILabel new];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont labelFontSize] weight:UIFontWeightRegular];
        [_valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        _slider = [UISlider new];
        [_slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
        UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _valueLabel]];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, _slider]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        ]];
    }
    return self;
}

- (void)updateValueLabel {
    self.valueLabel.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(self.slider.value * 100)];
}

- (void)sliderChanged {
    // Snap to 5% steps so the value is easy to hit with a finger
    self.slider.value = roundf(self.slider.value * 20) / 20;
    [self updateValueLabel];
    if (self.onChange) self.onChange(self.slider.value);
}

@end

#pragma mark - Log

@interface VOTLogViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@end

@implementation VOTLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = VOTLocalized(@"LOG");
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
    [self.view addSubview:self.textView];
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(clear)];
    self.navigationItem.rightBarButtonItems = @[share, clear];
    [self reload];
}

- (void)reload {
    NSString *text = VOTLogText();
    self.textView.text = text.length ? text : VOTLocalized(@"LOG_EMPTY");
    [self.textView scrollRangeToVisible:NSMakeRange(self.textView.text.length, 0)];
}

- (void)share:(UIBarButtonItem *)sender {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[VOTLogText()] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)clear {
    VOTLogClear();
    [self reload];
}

@end

#pragma mark - Settings

typedef NS_ENUM(NSInteger, VOTSettingsSection) {
    VOTSettingsSectionNow,
    VOTSettingsSectionLanguage,
    VOTSettingsSectionVoice,
    VOTSettingsSectionBehavior,
    VOTSettingsSectionVolume,
    VOTSettingsSectionDiagnostics,
    VOTSettingsSectionAbout,
    VOTSettingsSectionCount,
};

@implementation VOTSettingsViewController

+ (void)presentFromViewController:(UIViewController *)presenter currentVideoLanguage:(NSString *)language {
    VOTSettingsViewController *settings = [VOTSettingsViewController new];
    settings.currentVideoLanguage = language;
    [settings presentFromViewController:presenter];
}

- (void)presentFromViewController:(UIViewController *)presenter {
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:self];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)translationStateDidChange:(NSNotification *)notification {
    if (!self.translationStateProvider || !self.isViewLoaded) return;
    if (self.currentVideoLanguageProvider) self.currentVideoLanguage = self.currentVideoLanguageProvider();
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:VOTSettingsSectionNow];
    [sections addIndex:VOTSettingsSectionLanguage];
    [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
}

- (UITableViewCell *)translationToggleCell {
    VOTTranslationState state = self.translationStateProvider();
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = VOTLocalized(@"TRANSLATION_TOGGLE");
    cell.textLabel.font = [UIFont systemFontOfSize:[UIFont labelFontSize] weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = self.translationStatusProvider ? self.translationStatusProvider() : nil;
    cell.detailTextLabel.textColor = state == VOTTranslationStateOn ? [UIColor systemBlueColor] : state == VOTTranslationStateLoading ? [UIColor systemOrangeColor] : [UIColor secondaryLabelColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [UISwitch new];
    toggle.on = state == VOTTranslationStateOn || state == VOTTranslationStateLoading;
    toggle.enabled = state != VOTTranslationStateNoVideo;
    [toggle addTarget:self action:@selector(translationToggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)translationToggleChanged:(UISwitch *)toggle {
    if (self.translationToggleHandler) self.translationToggleHandler(toggle.on);
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = VOTLocalized(@"SETTINGS_TITLE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(translationStateDidChange:) name:VOTTranslationStateDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.currentVideoLanguageProvider) self.currentVideoLanguage = self.currentVideoLanguageProvider();
    [self.tableView reloadData];
}

- (void)signIn {
    VOTLoginViewController *login = [VOTLoginViewController new];
    __weak VOTSettingsViewController *weakSelf = self;
    login.completion = ^(BOOL signedIn) {
        // Signing in only makes sense for lively voices, so turn them on
        if (signedIn && !VOTLivelyVoice()) VOTSetSetting(VOTVoiceTypeKey, @"lively");
        [weakSelf.tableView reloadData];
    };
    [self.navigationController pushViewController:login animated:YES];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString *)languageList:(NSArray<NSString *> *)codes {
    if (!codes.count) return VOTLocalized(@"NONE");
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *code in codes) [names addObject:VOTLanguageName(code)];
    return [names componentsJoinedByString:@", "];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VOTSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case VOTSettingsSectionNow: return self.translationStateProvider ? 1 : 0;
        case VOTSettingsSectionLanguage: return self.currentVideoLanguage ? 4 : 3;
        case VOTSettingsSectionVoice: return 2;
        case VOTSettingsSectionBehavior: return 4;
        case VOTSettingsSectionVolume: return 2;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case VOTSettingsSectionLanguage: return VOTLocalized(@"SECTION_LANGUAGE");
        case VOTSettingsSectionVoice: return VOTLocalized(@"SECTION_VOICE");
        case VOTSettingsSectionBehavior: return VOTLocalized(@"SECTION_BEHAVIOR");
        case VOTSettingsSectionVolume: return VOTLocalized(@"SECTION_VOLUME");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case VOTSettingsSectionNow:
            if (!self.translationStateProvider) return nil;
            return VOTAutoTranslate() ? VOTLocalized(@"TRANSLATION_TOGGLE_FOOTER_AUTO") : VOTLocalized(@"TRANSLATION_TOGGLE_FOOTER");
        case VOTSettingsSectionLanguage:
            return [NSString stringWithFormat:VOTLocalized(@"MY_LANGUAGE_FOOTER"), VOTLanguageName(VOTResponseLang())];
        case VOTSettingsSectionVoice:
            return [VOTResponseLang() isEqualToString:@"ru"] ? VOTLocalized(@"VOICE_FOOTER") : VOTLocalized(@"VOICE_FOOTER_NOT_RU");
        case VOTSettingsSectionBehavior: return VOTLocalized(@"BEHAVIOR_FOOTER");
        case VOTSettingsSectionDiagnostics: return VOTLocalized(@"LOG_FOOTER");
        case VOTSettingsSectionAbout: return VOTLocalized(@"ABOUT_FOOTER");
        default: return nil;
    }
}

- (UITableViewCell *)valueCellWithTitle:(NSString *)title value:(NSString *)value {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"value"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"value"];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)switchCellWithTitle:(NSString *)title key:(NSString *)key {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.textLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [UISwitch new];
    toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:key];
    toggle.accessibilityIdentifier = key;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)switchChanged:(UISwitch *)toggle {
    VOTSetSetting(toggle.accessibilityIdentifier, @(toggle.on));
    // The hint under the translation switch depends on auto-translate
    if (self.translationStateProvider && [toggle.accessibilityIdentifier isEqualToString:VOTAutoTranslateKey])
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VOTSettingsSectionNow] withRowAnimation:UITableViewRowAnimationNone];
}

- (UITableViewCell *)sliderCellWithTitle:(NSString *)title key:(NSString *)key value:(float)value {
    VOTSliderCell *cell = [[VOTSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.titleLabel.text = title;
    cell.slider.value = value;
    [cell updateValueLabel];
    cell.onChange = ^(float newValue) {
        VOTSetSetting(key, @(newValue));
    };
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case VOTSettingsSectionNow:
            return [self translationToggleCell];
        case VOTSettingsSectionLanguage:
            switch (indexPath.row) {
                case 0: return [self valueCellWithTitle:VOTLocalized(@"MY_LANGUAGE") value:VOTLanguageName(VOTResponseLang())];
                case 1: return [self valueCellWithTitle:VOTLocalized(@"DONT_TRANSLATE_ALSO") value:[self languageList:VOTDontTranslateLanguages()]];
                case 2: {
                    NSString *lang = VOTRequestLang();
                    return [self valueCellWithTitle:VOTLocalized(@"REQUEST_LANG") value:[lang isEqualToString:@"auto"] ? VOTLocalized(@"AUTO_DETECT") : VOTLanguageName(lang)];
                }
                default: {
                    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
                    cell.textLabel.text = VOTLocalized(@"CURRENT_VIDEO_LANGUAGE");
                    cell.detailTextLabel.text = VOTLanguageName(self.currentVideoLanguage);
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    return cell;
                }
            }
        case VOTSettingsSectionVoice: {
            if (indexPath.row == 0) return [self valueCellWithTitle:VOTLocalized(@"VOICE_TYPE") value:VOTLocalized(VOTLivelyVoice() ? @"VOICE_LIVELY" : @"VOICE_STANDARD")];
            NSString *account = VOTAccountToken()
                ? [NSString stringWithFormat:VOTLocalized(@"SIGNED_IN_UNTIL"), [NSDateFormatter localizedStringFromDate:VOTAccountExpiration() dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle]]
                : VOTLocalized(@"SIGN_IN");
            return [self valueCellWithTitle:VOTLocalized(@"YANDEX_ACCOUNT") value:account];
        }
        case VOTSettingsSectionBehavior:
            switch (indexPath.row) {
                case 0: return [self switchCellWithTitle:VOTLocalized(@"AUTO_TRANSLATE") key:VOTAutoTranslateKey];
                case 1: return [self switchCellWithTitle:VOTLocalized(@"SHORTS_AUTO_TRANSLATE") key:VOTShortsAutoTranslateKey];
                case 2: return [self switchCellWithTitle:VOTLocalized(@"SHORTS_BUTTON") key:VOTShortsButtonKey];
                default: return [self switchCellWithTitle:VOTLocalized(@"YouVOTUploadAudio_KEY") key:VOTUploadAudioKey];
            }
        case VOTSettingsSectionVolume:
            return indexPath.row == 0
                ? [self sliderCellWithTitle:VOTLocalized(@"ORIGINAL_VOLUME") key:VOTOriginalVolumeKey value:VOTOriginalVolume()]
                : [self sliderCellWithTitle:VOTLocalized(@"TRANSLATION_VOLUME") key:VOTTranslationVolumeKey value:VOTTranslationVolume()];
        case VOTSettingsSectionDiagnostics:
            return [self valueCellWithTitle:VOTLocalized(@"LOG") value:nil];
        default: {
            UITableViewCell *cell = [self valueCellWithTitle:@"voice-over-translation" value:@"GitHub"];
            cell.textLabel.textColor = self.view.tintColor;
            return cell;
        }
    }
}

- (void)pushOptionsWithTitle:(NSString *)title values:(NSArray<NSString *> *)values titles:(NSArray<NSString *> *)titles selected:(NSArray<NSString *> *)selected multiple:(BOOL)multiple footer:(NSString *)footer onChange:(void (^)(NSArray<NSString *> *))onChange {
    VOTOptionsViewController *options = [VOTOptionsViewController new];
    options.title = title;
    options.values = values;
    options.titles = titles;
    options.selected = [NSMutableOrderedSet orderedSetWithArray:selected];
    options.multiple = multiple;
    options.footer = footer;
    options.onChange = onChange;
    [self.navigationController pushViewController:options animated:YES];
}

- (NSArray<NSString *> *)languageNames:(NSArray<NSString *> *)codes {
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *code in codes) [names addObject:VOTLanguageName(code)];
    return names;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == VOTSettingsSectionDiagnostics) {
        [self.navigationController pushViewController:[VOTLogViewController new] animated:YES];
        return;
    }
    if (indexPath.section == VOTSettingsSectionAbout) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/ilyhalight/voice-over-translation"] options:@{} completionHandler:nil];
        return;
    }
    if (indexPath.section == VOTSettingsSectionVoice) {
        if (indexPath.row == 0) {
            [self pushOptionsWithTitle:VOTLocalized(@"VOICE_TYPE") values:@[@"standard", @"lively"] titles:@[VOTLocalized(@"VOICE_STANDARD"), VOTLocalized(@"VOICE_LIVELY")] selected:@[VOTLivelyVoice() ? @"lively" : @"standard"] multiple:NO footer:VOTLocalized(@"VOICE_FOOTER") onChange:^(NSArray<NSString *> *selected) {
                VOTSetSetting(VOTVoiceTypeKey, selected.firstObject);
            }];
        } else if (VOTAccountToken()) {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:VOTLocalized(@"YANDEX_ACCOUNT") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            [sheet addAction:[UIAlertAction actionWithTitle:VOTLocalized(@"SIGN_OUT") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
                VOTSignOut();
                [tableView reloadData];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:VOTLocalized(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            sheet.popoverPresentationController.sourceView = cell;
            sheet.popoverPresentationController.sourceRect = cell.bounds;
            [self presentViewController:sheet animated:YES completion:nil];
        } else {
            [self signIn];
        }
        return;
    }
    if (indexPath.section != VOTSettingsSectionLanguage) return;
    switch (indexPath.row) {
        case 0: {
            NSArray *codes = VOTResponseLanguages();
            [self pushOptionsWithTitle:VOTLocalized(@"MY_LANGUAGE") values:codes titles:[self languageNames:codes] selected:@[VOTResponseLang()] multiple:NO footer:VOTLocalized(@"MY_LANGUAGE_OPTIONS_FOOTER") onChange:^(NSArray<NSString *> *selected) {
                VOTSetSetting(VOTResponseLangKey, selected.firstObject);
            }];
            break;
        }
        case 1: {
            NSMutableArray *codes = [VOTRequestLanguages() mutableCopy];
            [codes removeObject:VOTResponseLang()];
            [self pushOptionsWithTitle:VOTLocalized(@"DONT_TRANSLATE_ALSO") values:codes titles:[self languageNames:codes] selected:VOTDontTranslateLanguages() multiple:YES footer:VOTLocalized(@"DONT_TRANSLATE_FOOTER") onChange:^(NSArray<NSString *> *selected) {
                VOTSetSetting(VOTDontTranslateKey, selected);
            }];
            break;
        }
        case 2: {
            NSArray *codes = [@[@"auto"] arrayByAddingObjectsFromArray:VOTRequestLanguages()];
            NSMutableArray *titles = [[self languageNames:VOTRequestLanguages()] mutableCopy];
            [titles insertObject:VOTLocalized(@"AUTO_DETECT") atIndex:0];
            [self pushOptionsWithTitle:VOTLocalized(@"REQUEST_LANG") values:codes titles:titles selected:@[VOTRequestLang()] multiple:NO footer:VOTLocalized(@"REQUEST_LANG_FOOTER") onChange:^(NSArray<NSString *> *selected) {
                VOTSetSetting(VOTRequestLangKey, selected.firstObject);
            }];
            break;
        }
    }
}

@end
