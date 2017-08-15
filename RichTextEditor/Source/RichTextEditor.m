//
//  RichTextEditor.m
//  RichTextEdtor
//
//  Created by Aryan Gh on 7/21/13.
//  Copyright (c) 2013 Aryan Ghassemi. All rights reserved.
//
//  Modified heavily by Deadpikle
//  https://github.com/Deadpikle/iOS-Rich-Text-Editor
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

// stackoverflow.com/questions/26454037/uitextview-text-selection-and-highlight-jumping-in-ios-8

#import "RichTextEditor.h"
#import "RichTextEditorToolbar.h"

#import "UIFont+RichTextEditor.h"
#import "NSAttributedString+RichTextEditor.h"
#import "UIView+RichTextEditor.h"
#import "WZProtocolInterceptor.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <MobileCoreServices/MobileCoreServices.h>

#define RICHTEXTEDITOR_TOOLBAR_HEIGHT 40

@interface RichTextEditor() <RichTextEditorToolbarDelegate, RichTextEditorToolbarDataSource, UITextViewDelegate>

@property (nonatomic, strong) RichTextEditorToolbar *toolBar;

// Gets set to YES when the user starts changing attributes when there is no text selection (selecting bold, italic, etc)
// Gets set to NO  when the user changes selection or starts typing
@property (nonatomic, assign) BOOL typingAttributesInProgress;

@property float currSysVersion;
@property WZProtocolInterceptor *delegate_interceptor;
@property NSString *BULLET_STRING;
@property NSUInteger LEVELS_OF_UNDO;

@property BOOL justDeletedBackward;
@property BOOL isInTextDidChange;

@property CGFloat fontSizeChangeAmount;
@property CGFloat maxFontSize;
@property CGFloat minFontSize;

@end

@implementation RichTextEditor

+(NSString*)pasteboardDataType {
	return @"iOSRichTextEditor27";
}

#pragma mark - Initialization -

- (id)init {
    if (self = [super init]) {
        [self commonInitialization];
    }
    return self;
}

- (id)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        [self commonInitialization];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
	if (self = [super initWithCoder:aDecoder]) {
		[self commonInitialization];
	}
	return self;
}

- (void)setDelegate:(id)newDelegate {
	self.delegate_interceptor.receiver = newDelegate;
}

/*
 // TODO: Figure out if this can be overridden somehow without messing up the delegation system
- (id)delegate {
	return self.delegate_interceptor.receiver;
}
*/

- (id)textViewDelegate {
	return self.delegate_interceptor.receiver;
}

- (void)commonInitialization {
	// Prevent the use of self.delegate = self
	// http://stackoverflow.com/questions/3498158/intercept-objective-c-delegate-messages-within-a-subclass
	Protocol *p = objc_getProtocol("UITextViewDelegate");
	self.delegate_interceptor = [[WZProtocolInterceptor alloc] initWithInterceptedProtocol:p];
	[self.delegate_interceptor setMiddleMan:self];
	[super setDelegate:(id)self.delegate_interceptor];
	
    self.borderColor = [UIColor lightGrayColor];
    self.borderWidth = 1.0;
	self.LEVELS_OF_UNDO = 15;
	self.BULLET_STRING = @"•\u00A0"; // bullet is \u2022
	self.fontSizeChangeAmount = 6.0f;
	self.maxFontSize = 128.0f;
	self.minFontSize = 8.0f;
	
	self.toolBar = [[RichTextEditorToolbar alloc] initWithFrame:CGRectMake(0, 0, [self currentScreenBoundsDependOnOrientation].size.width, RICHTEXTEDITOR_TOOLBAR_HEIGHT)
													   delegate:self
													 dataSource:self];
	
	self.typingAttributesInProgress = NO;
    self.inBulletedList = NO;
    
    // Instead of hard-coding the default indentation size, which can make bulleted lists look a little
    // odd when increasing/decreasing their indent, use a \t character width instead
    // The old defaultIndentationSize was 15
	
    // TODO: readjust this defaultIndentationSize when font size changes? Might make things weird.
	NSDictionary *dictionary = [self dictionaryAtIndex:self.selectedRange.location];
    CGSize expectedStringSize = [@"\t" sizeWithAttributes:dictionary];
	self.defaultIndentationSize = expectedStringSize.width;
    
	[self setupMenuItems];
	[self updateToolbarState];
	if (self.rteDelegate && [self.rteDelegate respondsToSelector:@selector(levelsOfUndo)]) {
		self.undoManager.levelsOfUndo = [self.rteDelegate levelsOfUndo];
	}
	else {
		self.undoManager.levelsOfUndo = self.LEVELS_OF_UNDO;
	}
	
    // http://stackoverflow.com/questions/26454037/uitextview-text-selection-and-highlight-jumping-in-ios-8
    self.currSysVersion = UIDevice.currentDevice.systemVersion.floatValue;
	if (self.currSysVersion >= 8.0) {
        self.layoutManager.allowsNonContiguousLayout = NO;
	}
	// make sure we start on a blank string if needed and at the top of the text box
	self.selectedRange = NSMakeRange(0, 0);
	if ([[self.textStorage.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:@""]) {
		[self.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
	}
}

-(void)dealloc {
	self.delegate_interceptor.receiver = nil;
    self.toolBar = nil;
}

- (void)enableUndoToolbarButton:(BOOL)shouldEnable {
	[self.toolBar enableUndoButton:shouldEnable];
}

- (void)enableRedoToolbarButton:(BOOL)shouldEnable {
	[self.toolBar enableRedoButton:shouldEnable];
}

- (void)changeToAttributedString:(NSAttributedString*)string {
	[self.textStorage setAttributedString:string];
}

-(void)sendDelegatePreviewChangeOfType:(RichTextEditorPreviewChange)type {
	if (self.rteDelegate && [self.rteDelegate respondsToSelector:@selector(richTextEditor:changeAboutToOccurOfType:)]) {
		[self.rteDelegate richTextEditor:self changeAboutToOccurOfType:type];
	}
}

- (void)textViewDidChange:(UITextView *)textView {
	if (!self.isInTextDidChange){
		self.isInTextDidChange = YES;
		[self applyBulletListIfApplicable];
		[self deleteBulletListWhenApplicable];
		self.isInTextDidChange = NO;
	}
	self.justDeletedBackward = NO;
	[self sendDelegateTVChanged];
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
	if ([text isEqualToString:@"\n"]) {
		[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeEnter];
		self.inBulletedList = [self isInBulletedList];
	}
	if ([text isEqualToString:@" "]) {
		[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeSpace];
	}
	if (self.delegate_interceptor.receiver && [self.delegate_interceptor.receiver respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementText:)]) {
		return [self.delegate_interceptor.receiver textView:textView shouldChangeTextInRange:range replacementText:text];
	}
	return YES;
}

- (void)textViewDidChangeSelection:(UITextView *)textView {
	//NSLog(@"[RTE] Changed selection to location: %lu, length: %lu", (unsigned long)textView.selectedRange.location, (unsigned long)textView.selectedRange.length);
    [self updateToolbarState];
    [self setNeedsLayout];
    [self scrollRangeToVisible:self.selectedRange]; // fixes issue with cursor moving to top via keyboard and RTE not scrolling
    
	NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	BOOL currentParagraphHasBullet = [[self.attributedText.string substringFromIndex:rangeOfCurrentParagraph.location] hasPrefix:self.BULLET_STRING];
	if (currentParagraphHasBullet) {
        self.inBulletedList = YES;
	}
	[self sendDelegateTypingAttrsUpdate];
	if (self.delegate_interceptor.receiver && [self.delegate_interceptor.receiver respondsToSelector:@selector(textViewDidChangeSelection:)]) {
		[self.delegate_interceptor.receiver textViewDidChangeSelection:self];
	}
}

- (BOOL)isInBulletedList {
	NSRange rangeOfCurrentParagraph = [self.textStorage firstParagraphRangeFromTextRange:self.selectedRange];
	return [[self.textStorage.string substringFromIndex:rangeOfCurrentParagraph.location] hasPrefix:self.BULLET_STRING];
}

- (BOOL)isInEmptyBulletedListItem {
	NSRange rangeOfCurrentParagraph = [self.textStorage firstParagraphRangeFromTextRange:self.selectedRange];
	return [[self.textStorage.string substringFromIndex:rangeOfCurrentParagraph.location] isEqualToString:self.BULLET_STRING];
}

- (void)sendDelegateTypingAttrsUpdate {
	if (self.rteDelegate) {
		NSDictionary *attributes = [self typingAttributes];
		UIFont *font = [attributes objectForKey:NSFontAttributeName];
		UIColor *fontColor = [attributes objectForKey:NSForegroundColorAttributeName];
		UIColor *backgroundColor = [attributes objectForKey:NSBackgroundColorAttributeName]; // may want NSBackgroundColorAttributeName
		BOOL isInBulletedList = [self isInBulletedList];
		[self.rteDelegate selectionForEditor:self changedTo:[self selectedRange] isBold:[font isBold] isItalic:[font isItalic] isUnderline:[self isCurrentFontUnderlined] isInBulletedList:isInBulletedList textBackgroundColor:backgroundColor textColor:fontColor];
	}
}

- (void)sendDelegateTVChanged {
	if (self.delegate_interceptor.receiver && [self.delegate_interceptor.receiver respondsToSelector:@selector(textViewDidChange:)]) {
		[self.delegate_interceptor.receiver textViewDidChange:self];
	}
}

- (BOOL)isCurrentFontUnderlined {
	NSDictionary *dictionary = [self typingAttributes];
	NSNumber *existingUnderlineStyle = [dictionary objectForKey:NSUnderlineStyleAttributeName];
	
	if (!existingUnderlineStyle || existingUnderlineStyle.intValue == NSUnderlineStyleNone) {
		return NO;
	}
	return YES;
}

// see http://stackoverflow.com/a/25862878/3938401 for a discussion on deleteBackward bugs not working in iOS 8.0 up until 8.3
- (void)deleteBackward {
	self.justDeletedBackward = YES;
	[super deleteBackward];
}

#pragma mark - Override Methods -

- (void)paste:(id)sender {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangePaste];
	if (self.allowsRichTextPasteOnlyFromThisClass) {
		if ([[UIPasteboard generalPasteboard] dataForPasteboardType:[RichTextEditor pasteboardDataType]]) {
			[super paste:sender]; // just call paste so we don't have to bother doing the check again
		}
		else {
			[self pasteAsPlainText:(NSString*)[[UIPasteboard generalPasteboard] dataForPasteboardType:(NSString*)kUTTypeUTF8PlainText]];
		}
	}
	else {
		[super paste:sender];
	}
}

- (void)pasteAsPlainText:(NSString*)stringToPaste {
	// 1) Delete current selection (a paste would overwrite it) at selectedRange
	NSUInteger selectedLocation = self.selectedRange.location;
	[self.textStorage deleteCharactersInRange:self.selectedRange];
	// 2) Insert stringToPaste at selectedRange
	[self.textStorage insertAttributedString:[[NSAttributedString alloc] initWithString:stringToPaste] atIndex:selectedLocation];
}

- (void)cut:(id)sender {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeCut];
	[super cut:sender];
}

- (void)copy:(id)sender {
	[super copy:sender];
	UIPasteboard *currentPasteboard = [UIPasteboard generalPasteboard];
	[currentPasteboard setData:[@"" dataUsingEncoding:NSUTF8StringEncoding] forPasteboardType:[RichTextEditor pasteboardDataType]];
}

- (void)setSelectedTextRange:(UITextRange *)selectedTextRange {
	[super setSelectedTextRange:selectedTextRange];
	[self updateToolbarState];
	self.typingAttributesInProgress = NO;
}

- (BOOL)canBecomeFirstResponder {
	if (![self.dataSource respondsToSelector:@selector(shouldDisplayToolbarForRichTextEditor:)] ||
		[self.dataSource shouldDisplayToolbarForRichTextEditor:self]) {
		self.inputAccessoryView = self.toolBar;
		// Redraw in case enabled features have changed
		[self.toolBar redraw];
	}
	else {
		self.inputAccessoryView = nil;
	}
	// changed to YES so that we can use keyboard shortcuts
	return YES; /*[super canBecomeFirstResponder]*/
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    RichTextEditorFeature features = [self featuresEnabledForRichTextEditorToolbar];
    
    if (action == @selector(richTextEditorToolbarDidSelectBold)) {
        return ([self.dataSource respondsToSelector:@selector(shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:)] &&
                [self.dataSource shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:self]) && (features & RichTextEditorFeatureBold || features & RichTextEditorFeatureAll) && self.isEditable;
    }
    
    if (action == @selector(richTextEditorToolbarDidSelectItalic)) {
        return ([self.dataSource respondsToSelector:@selector(shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:)] &&
                [self.dataSource shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:self])  && (features & RichTextEditorFeatureItalic || features & RichTextEditorFeatureAll) && self.isEditable;
    }
    
    if (action == @selector(richTextEditorToolbarDidSelectUnderline)) {
        return ([self.dataSource respondsToSelector:@selector(shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:)] &&
                [self.dataSource shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:self])  && (features & RichTextEditorFeatureUnderline || features & RichTextEditorFeatureAll) && self.isEditable;
    }
    
    if (action == @selector(richTextEditorToolbarDidSelectStrikeThrough)) {
        return ([self.dataSource respondsToSelector:@selector(shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:)] &&
                [self.dataSource shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:self]) && (features & RichTextEditorFeatureStrikeThrough || features & RichTextEditorFeatureAll) && self.isEditable;
    }
    
    if (action == @selector(selectParagraph:) && self.selectedRange.length > 0)
        return YES;
    
    return [super canPerformAction:action withSender:sender];
}


- (void)setAttributedText:(NSAttributedString *)attributedText {
	[super setAttributedText:attributedText];
	[self updateToolbarState];
}

- (void)setText:(NSString *)text {
	[super setText:text];
	[self updateToolbarState];
}

- (void)setFont:(UIFont *)font {
	[super setFont:font];
	[self updateToolbarState];
}

//- (void)setEditable:(BOOL)editable {
//    if(editable) {
//        [self setupMenuItems];
//    }else {
//        [[UIMenuController sharedMenuController] setMenuItems:@[]];
//
//    }
//}

#pragma mark - MenuController Methods -

- (void)setupMenuItems {
	UIMenuItem *selectParagraph = [[UIMenuItem alloc] initWithTitle:@"Select Paragraph" action:@selector(selectParagraph:)];
	UIMenuItem *boldItem = [[UIMenuItem alloc] initWithTitle:@"Bold" action:@selector(richTextEditorToolbarDidSelectBold)];
	UIMenuItem *italicItem = [[UIMenuItem alloc] initWithTitle:@"Italic" action:@selector(richTextEditorToolbarDidSelectItalic)];
	UIMenuItem *underlineItem = [[UIMenuItem alloc] initWithTitle:@"Underline" action:@selector(richTextEditorToolbarDidSelectUnderline)];
	//UIMenuItem *strikeThroughItem = [[UIMenuItem alloc] initWithTitle:@"Strike" action:@selector(richTextEditorToolbarDidSelectStrikeThrough)]; // buggy on ios 8, scrolls the text for some reason; not sure why
	
	[[UIMenuController sharedMenuController] setMenuItems:@[selectParagraph, boldItem, italicItem, underlineItem]];
}

- (void)selectParagraph:(id)sender {
	NSRange range = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	[self setSelectedRange:range];
    
	[[UIMenuController sharedMenuController] setTargetRect:[self frameOfTextAtRange:self.selectedRange] inView:self];
	[[UIMenuController sharedMenuController] setMenuVisible:YES animated:YES];
}

#pragma mark - Public Methods -

- (void)setHtmlString:(NSString *)htmlString {
	NSMutableAttributedString *attr = [[RichTextEditor attributedStringFromHTMLString:htmlString] mutableCopy];
	if (attr) {
		if ([attr.string hasSuffix:@"\n"]) {
			[attr replaceCharactersInRange:NSMakeRange(attr.length - 1, 1) withString:@""];
		}
		self.attributedText = attr;
	}
}

- (NSString *)htmlString {
    return [RichTextEditor htmlStringFromAttributedText:self.attributedText];
}

+(NSString *)htmlStringFromAttributedText:(NSAttributedString*)text {
	NSData *data = [text dataFromRange:NSMakeRange(0, text.length)
                    documentAttributes:
                        @{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
                        NSCharacterEncodingDocumentAttribute: [NSNumber numberWithInt:NSUTF8StringEncoding]}
                    error:nil];
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+(NSAttributedString*)attributedStringFromHTMLString:(NSString *)htmlString {
	NSError *error;
	NSData *data = [htmlString dataUsingEncoding:NSUTF8StringEncoding];
	NSAttributedString *str =
		[[NSAttributedString alloc] initWithData:data
										 options:@{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
												   NSCharacterEncodingDocumentAttribute: [NSNumber numberWithInt:NSUTF8StringEncoding]}
							  documentAttributes:nil error:&error];
	if (!error) {
		return str;
	}
	NSLog(@"[RTE] Attributed string from HTML string %@", error);
    return nil;
}

- (void)setBorderColor:(UIColor *)borderColor {
    self.layer.borderColor = borderColor.CGColor;
}

- (void)setBorderWidth:(CGFloat)borderWidth {
    self.layer.borderWidth = borderWidth;
}

#pragma mark - RichTextEditorToolbarDelegate Methods -

- (void)richTextEditorToolbarDidDismissViewController {
	if (!self.isFirstResponder) {
		[self becomeFirstResponder];
	}
}

// To fix the toolbar issues, may just want to set self.typingAttributesInProgress to YES instead
- (void)richTextEditorToolbarDidSelectBold {
	UIFont *font = [[self typingAttributes] objectForKey:NSFontAttributeName];
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeBold];
	[self applyFontAttributesToSelectedRangeWithBoldTrait:[NSNumber numberWithBool:![font isBold]] italicTrait:nil fontName:nil fontSize:nil];
	[self sendDelegateTypingAttrsUpdate];
	[self sendDelegateTVChanged];
}

- (void)richTextEditorToolbarDidSelectItalic {
	UIFont *font = [[self typingAttributes] objectForKey:NSFontAttributeName];
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeItalic];
	[self applyFontAttributesToSelectedRangeWithBoldTrait:nil italicTrait:[NSNumber numberWithBool:![font isItalic]] fontName:nil fontSize:nil];
	[self sendDelegateTypingAttrsUpdate];
	[self sendDelegateTVChanged];
}

- (void)richTextEditorToolbarDidSelectUnderline {
	NSDictionary *dictionary = [self typingAttributes];
	NSNumber *existingUnderlineStyle = [dictionary objectForKey:NSUnderlineStyleAttributeName];
	if (!existingUnderlineStyle || existingUnderlineStyle.intValue == NSUnderlineStyleNone) {
		existingUnderlineStyle = [NSNumber numberWithInteger:NSUnderlineStyleSingle];
	}
	else {
		existingUnderlineStyle = [NSNumber numberWithInteger:NSUnderlineStyleNone];
	}
	
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeUnderline];
	[self applyAttributesToSelectedRange:existingUnderlineStyle forKey:NSUnderlineStyleAttributeName];
	[self sendDelegateTypingAttrsUpdate];
	[self sendDelegateTVChanged];
}

- (void)richTextEditorToolbarDidSelectFontSize:(NSNumber *)fontSize {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeFontSize];
	[self applyFontAttributesToSelectedRangeWithBoldTrait:nil italicTrait:nil fontName:nil fontSize:fontSize];
	[self sendDelegateTypingAttrsUpdate];
	[self sendDelegateTVChanged];
}

- (void)richTextEditorToolbarDidSelectFontWithName:(NSString *)fontName {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeFontName];
	[self applyFontAttributesToSelectedRangeWithBoldTrait:nil italicTrait:nil fontName:fontName fontSize:nil];
	[self sendDelegateTypingAttrsUpdate];
	[self sendDelegateTVChanged];
}

- (void)richTextEditorToolbarDidSelectTextBackgroundColor:(UIColor *)color {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeHighlight];
	NSRange selectedRange = self.selectedRange;
	if (color) {
		[self applyAttributesToSelectedRange:color forKey:NSBackgroundColorAttributeName];
	}
	else {
		[self removeAttributeForKeyFromSelectedRange:NSBackgroundColorAttributeName];
	}
	[self setSelectedRange:NSMakeRange(selectedRange.location + selectedRange.length, 0)];
	[self sendDelegateTypingAttrsUpdate];
	[self sendDelegateTVChanged];
}

-(void)userSelectedIncreaseIndent {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeIndentIncrease];
	[self richTextEditorToolbarDidSelectParagraphIndentation:ParagraphIndentationIncrease];
	[self sendDelegateTVChanged];
}

-(void)userSelectedDecreaseIndent {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeIndentDecrease];
	[self richTextEditorToolbarDidSelectParagraphIndentation:ParagraphIndentationDecrease];
	[self sendDelegateTVChanged];
}

- (void)richTextEditorToolbarDidSelectTextForegroundColor:(UIColor *)color {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeFontColor];
	NSRange selectedRange = [self selectedRange];
	if (color) {
		[self applyAttributesToSelectedRange:color forKey:NSForegroundColorAttributeName];
	}
	else {
		[self removeAttributeForKeyFromSelectedRange:NSForegroundColorAttributeName];
	}
	[self setSelectedRange:NSMakeRange(selectedRange.location + selectedRange.length, 0)];
	[self sendDelegateTypingAttrsUpdate];
	[self sendDelegateTVChanged];
}

- (void)richTextEditorToolbarDidSelectStrikeThrough {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeStrikethrough];
    NSDictionary *dictionary = [self typingAttributes];
	NSNumber *existingUnderlineStyle = [dictionary objectForKey:NSStrikethroughStyleAttributeName];
	if (!existingUnderlineStyle || existingUnderlineStyle.intValue == NSUnderlineStyleNone) {
		existingUnderlineStyle = [NSNumber numberWithInteger:NSUnderlineStyleSingle];
	}
	else {
		existingUnderlineStyle = [NSNumber numberWithInteger:NSUnderlineStyleNone];
	}
	[self applyAttributesToSelectedRange:existingUnderlineStyle forKey:NSStrikethroughStyleAttributeName];
	[self sendDelegateTypingAttrsUpdate];
	[self sendDelegateTVChanged];
}

// try/catch blocks on undo/redo because it doesn't work right with bulleted lists when BULLET_STRING has more than 1 character
- (void)richTextEditorToolbarDidSelectUndo {
    @try {
        BOOL shouldUseUndoManager = YES;
        if ([self.dataSource respondsToSelector:@selector(handlesUndoRedoForText)]) {
            if ([self.rteDelegate handlesUndoRedoForText]) {
                [self.rteDelegate userPerformedUndo];
                shouldUseUndoManager = NO;
            }
        }
		if (shouldUseUndoManager && [[self undoManager] canUndo]) {
            [self.undoManager undo];
		}
    }
    @catch (NSException *e) {
        NSLog(@"[RTE] Couldn't perform undo: %@", [e description]);
        [self.undoManager removeAllActions];
    }
}

- (void)richTextEditorToolbarDidSelectRedo {
    @try {
        BOOL shouldUseUndoManager = YES;
        if ([self.dataSource respondsToSelector:@selector(handlesUndoRedoForText)]) {
            if ([self.rteDelegate handlesUndoRedoForText]) {
                [self.rteDelegate userPerformedRedo];
                shouldUseUndoManager = NO;
            }
        }
        if (shouldUseUndoManager && [[self undoManager] canRedo])
            [self.undoManager redo];
    }
    @catch (NSException *e) {
        NSLog(@"[RTE] Couldn't perform redo: %@", [e description]);
        [self.undoManager removeAllActions];
    }
}

- (void)richTextEditorToolbarDidSelectDismissKeyboard {
    [self resignFirstResponder];
}

- (void)richTextEditorToolbarDidSelectParagraphIndentation:(ParagraphIndentation)paragraphIndentation {
    __block NSDictionary *dictionary;
    __block NSMutableParagraphStyle *paragraphStyle;
	[self enumerateThroughParagraphsInRange:self.selectedRange withBlock:^(NSRange paragraphRange){
        dictionary = [self dictionaryAtIndex:paragraphRange.location];
        paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
		if (!paragraphStyle) {
			paragraphStyle = [[NSMutableParagraphStyle alloc] init];
		}
		if (paragraphIndentation == ParagraphIndentationIncrease) {
			paragraphStyle.headIndent += self.defaultIndentationSize;
			paragraphStyle.firstLineHeadIndent += self.defaultIndentationSize;
		}
		else if (paragraphIndentation == ParagraphIndentationDecrease) {
			paragraphStyle.headIndent -= self.defaultIndentationSize;
			paragraphStyle.firstLineHeadIndent -= self.defaultIndentationSize;
			
			if (paragraphStyle.headIndent < 0) {
				paragraphStyle.headIndent = 0; // this is the right (as opposed to left) cursor placement
			}

			if (paragraphStyle.firstLineHeadIndent < 0) {
				paragraphStyle.firstLineHeadIndent = 0; // this affects left cursor placement
			}
		}
		[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:paragraphRange];
	}];
    
    // Following 2 lines allow the user to insta-type after indenting in a bulleted list
    NSRange range = NSMakeRange(self.selectedRange.location+self.selectedRange.length, 0);
    [self setSelectedRange:range];
    
    // Check to see if the current paragraph is blank. If it is, manually get the cursor to move with a weird hack.
    NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	BOOL currParagraphIsBlank = [[self.attributedText.string substringWithRange:rangeOfCurrentParagraph] isEqualToString:@""] ? YES: NO;
    if (currParagraphIsBlank) {
        [self setIndentationWithAttributes:dictionary paragraphStyle:paragraphStyle atRange:rangeOfCurrentParagraph];
    }
}

// Manually moves the cursor to the correct location. Ugly work around and weird but it works (at least in iOS 7).
// Basically what I do is add a " " with the correct indentation then delete it. For some reason with that
// and applying that attribute to the current typing attributes it moves the cursor to the right place.
-(void)setIndentationWithAttributes:(NSDictionary*)attributes paragraphStyle:(NSMutableParagraphStyle*)paragraphStyle atRange:(NSRange)range {
    NSMutableAttributedString *space = [[NSMutableAttributedString alloc] initWithString:@" " attributes:attributes];
    [space addAttributes:[NSDictionary dictionaryWithObject:paragraphStyle forKey:NSParagraphStyleAttributeName] range:NSMakeRange(0, 1)];
	[self.textStorage insertAttributedString:space atIndex:range.location];
    [self setSelectedRange:NSMakeRange(range.location, 1)];
    [self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:NSMakeRange(self.selectedRange.location+self.selectedRange.length-1, 1)];
    [self setSelectedRange:NSMakeRange(range.location, 0)];
	[self.textStorage deleteCharactersInRange:NSMakeRange(range.location, 1)];
    [self applyAttributeToTypingAttribute:paragraphStyle forKey:NSParagraphStyleAttributeName];
}

- (void)richTextEditorToolbarDidSelectParagraphFirstLineHeadIndent {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeParagraphFirstLineHeadIndent];
	[self enumerateThroughParagraphsInRange:self.selectedRange withBlock:^(NSRange paragraphRange){
		NSDictionary *dictionary = [self dictionaryAtIndex:paragraphRange.location];
		NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
		if (!paragraphStyle) {
			paragraphStyle = [[NSMutableParagraphStyle alloc] init];
		}
		if (paragraphStyle.headIndent == paragraphStyle.firstLineHeadIndent) {
			paragraphStyle.firstLineHeadIndent += self.defaultIndentationSize;
		}
		else {
			paragraphStyle.firstLineHeadIndent = paragraphStyle.headIndent;
		}
		[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:paragraphRange];
	}];
	[self sendDelegateTVChanged];
}

- (void)richTextEditorToolbarDidSelectTextAlignment:(NSTextAlignment)textAlignment {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeTextAlignment];
	[self enumerateThroughParagraphsInRange:self.selectedRange withBlock:^(NSRange paragraphRange){
		NSDictionary *dictionary = [self dictionaryAtIndex:paragraphRange.location];
		NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
		if (!paragraphStyle) {
			paragraphStyle = [[NSMutableParagraphStyle alloc] init];
		}
		paragraphStyle.alignment = textAlignment;
		[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:paragraphRange];
        [self setIndentationWithAttributes:dictionary paragraphStyle:paragraphStyle atRange:paragraphRange];
	}];
	[self updateToolbarState];
	[self sendDelegateTVChanged];
}

- (void)setAttributedString:(NSAttributedString*)attributedString {
	[self.textStorage setAttributedString:attributedString];
}

- (void)richTextEditorToolbarDidSelectBulletListWithCaller:(id)caller {
	if (self.currSysVersion < 8.0) {
        self.scrollEnabled = NO;
	}
	if (!self.isEditable)
		return;
	if (!self.isInTextDidChange) {
		[self sendDelegateTVChanged];
	}
	if (caller == self.toolBar) {
        self.inBulletedList = !self.inBulletedList;
	}
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeBullet];
	NSRange initialSelectedRange = self.selectedRange;
	NSArray *rangeOfParagraphsInSelectedText = [self.attributedText rangeOfParagraphsFromTextRange:self.selectedRange];
	NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	BOOL firstParagraphHasBullet = [[self.attributedText.string substringFromIndex:rangeOfCurrentParagraph.location] hasPrefix:self.BULLET_STRING];
    
    NSRange rangeOfPreviousParagraph = [self.attributedText firstParagraphRangeFromTextRange:NSMakeRange(rangeOfCurrentParagraph.location-1, 0)];
    NSDictionary *prevParaDict = [self dictionaryAtIndex:rangeOfPreviousParagraph.location];
    NSMutableParagraphStyle *prevParaStyle = [prevParaDict objectForKey:NSParagraphStyleAttributeName];
	
	__block NSInteger rangeOffset = 0;
	__block BOOL mustDecreaseIndentAfterRemovingBullet = NO;
	__block BOOL isInBulletedList = self.inBulletedList;
	
	[self enumerateThroughParagraphsInRange:self.selectedRange withBlock:^(NSRange paragraphRange){
		NSRange range = NSMakeRange(paragraphRange.location + rangeOffset, paragraphRange.length);
		NSDictionary *dictionary = [self dictionaryAtIndex:MAX((int)range.location-1, 0)];
		NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
		
		if (!paragraphStyle) {
			paragraphStyle = [[NSMutableParagraphStyle alloc] init];
		}
		BOOL currentParagraphHasBullet = [[self.attributedText.string substringFromIndex:range.location] hasPrefix:self.BULLET_STRING];
		if (firstParagraphHasBullet != currentParagraphHasBullet) {
			return;
		}
		if (currentParagraphHasBullet){
            // User hit the bullet button and is in a bulleted list so we should get rid of the bullet
			range = NSMakeRange(range.location, range.length - self.BULLET_STRING.length);
			[self.textStorage deleteCharactersInRange:NSMakeRange(range.location, self.BULLET_STRING.length)];
			paragraphStyle.firstLineHeadIndent = 0;
			paragraphStyle.headIndent = 0;
			rangeOffset = rangeOffset - self.BULLET_STRING.length;
			mustDecreaseIndentAfterRemovingBullet = YES;
			isInBulletedList = NO;
		}
		else {
            // We are adding a bullet
			range = NSMakeRange(range.location, range.length + self.BULLET_STRING.length);
			
			NSMutableAttributedString *bulletAttributedString = [[NSMutableAttributedString alloc] initWithString:self.BULLET_STRING attributes:nil];
            /* I considered manually removing any bold/italic/underline/strikethrough from the text, but 
             // decided against it. If the user wants bold bullets, let them have bold bullets!
            UIFont *prevFont = [dictionary objectForKey:NSFontAttributeName];
            UIFont *bulletFont = [UIFont fontWithName:[prevFont familyName] size:[prevFont pointSize]];
            NSMutableDictionary *bulletDict = [dictionary mutableCopy];
            [bulletDict setObject:bulletFont forKey:NSFontAttributeName];
            [bulletDict setObject:0 forKey:NSStrikethroughStyleAttributeName];
            [bulletDict setObject:0 forKey:NSUnderlineStyleAttributeName];
            */
            [bulletAttributedString setAttributes:dictionary range:NSMakeRange(0, self.BULLET_STRING.length)];
			
			[self.textStorage insertAttributedString:bulletAttributedString atIndex:range.location];
			
			CGSize expectedStringSize = [self.BULLET_STRING sizeWithAttributes:dictionary];
            
            // See if the previous paragraph has a bullet
            NSString *previousParagraph = [self.attributedText.string substringWithRange:rangeOfPreviousParagraph];
            BOOL doesPrefixWithBullet = [previousParagraph hasPrefix:self.BULLET_STRING];
            
            // Look at the previous paragraph to see what the firstLineHeadIndent should be for the
            // current bullet
            // if the previous paragraph has a bullet, use that paragraph's indent
            // if not, then use defaultIndentation size
			if (!doesPrefixWithBullet) {
                paragraphStyle.firstLineHeadIndent = self.defaultIndentationSize;
			}
			else {
				paragraphStyle.firstLineHeadIndent = prevParaStyle.firstLineHeadIndent;
			}
			paragraphStyle.headIndent = expectedStringSize.width;
			
			rangeOffset = rangeOffset + self.BULLET_STRING.length;
			isInBulletedList = YES;
		}
		[self.textStorage addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:range];
	}];
	
	// If paragraph is empty move cursor to front of bullet, so the user can start typing right away
    NSRange rangeForSelection;
	if (rangeOfParagraphsInSelectedText.count == 1 && rangeOfCurrentParagraph.length == 0 && isInBulletedList) {
        rangeForSelection = NSMakeRange(rangeOfCurrentParagraph.location + self.BULLET_STRING.length, 0);
	}
	else {
		if (initialSelectedRange.length == 0) {
            rangeForSelection = NSMakeRange(initialSelectedRange.location+rangeOffset, 0);
		}
		else {
			NSRange fullRange = [self fullRangeFromArrayOfParagraphRanges:rangeOfParagraphsInSelectedText];
            rangeForSelection = NSMakeRange(fullRange.location, fullRange.length+rangeOffset);
		}
	}
	if (mustDecreaseIndentAfterRemovingBullet) { // remove the extra indentation added by the bullet
		[self richTextEditorToolbarDidSelectParagraphIndentation:ParagraphIndentationDecrease];
	}
    //NSLog(@"[RTE] Range for end of bullet: %lu, %lu", (unsigned long)rangeForSelection.location, (unsigned long)rangeForSelection.length);
	if (self.currSysVersion < 8.0) {
		self.scrollEnabled = YES;
	}
	self.selectedRange = rangeForSelection;
}

- (void)richTextEditorToolbarDidSelectTextAttachment:(UIImage *)textAttachment {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeTextAttachment];
	NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
	[attachment setImage:textAttachment];
	NSAttributedString *attributedStringAttachment = [NSAttributedString attributedStringWithAttachment:attachment];
	NSDictionary *previousAttributes = [self dictionaryAtIndex:self.selectedRange.location];
	[self.textStorage insertAttributedString:attributedStringAttachment atIndex:self.selectedRange.location];
	[self.textStorage addAttributes:previousAttributes range:NSMakeRange(self.selectedRange.location, 1)];
	[self.textStorage endEditing];
	[self sendDelegateTVChanged];
}

- (UIViewController <RichTextEditorColorPicker> *)colorPickerForRichTextEditorToolbarWithAction:(RichTextEditorColorPickerAction)action {
	if ([self.dataSource respondsToSelector:@selector(colorPickerForRichTextEditor:withAction:)]) { // changed "forAction" to "withAction"
		return [self.dataSource colorPickerForRichTextEditor:self withAction:action];
    }
	return nil;
}

- (UIViewController <RichTextEditorFontPicker> *)fontPickerForRichTextEditorToolbar {
	if ([self.dataSource respondsToSelector:@selector(fontPickerForRichTextEditor:)]) {
		return [self.dataSource fontPickerForRichTextEditor:self];
	}
	return nil;
}

- (UIViewController <RichTextEditorFontSizePicker> *)fontSizePickerForRichTextEditorToolbar {
	if ([self.dataSource respondsToSelector:@selector(fontSizePickerForRichTextEditor:)]) {
		return [self.dataSource fontSizePickerForRichTextEditor:self];
	}
	return nil;
}

#pragma mark - Private Methods -

- (CGRect)frameOfTextAtRange:(NSRange)range {
	UITextRange *selectionRange = self.selectedTextRange;
	NSArray *selectionRects = [self selectionRectsForRange:selectionRange];
	CGRect completeRect = CGRectNull;
	for (UITextSelectionRect *selectionRect in selectionRects) {
		completeRect = (CGRectIsNull(completeRect)) ? selectionRect.rect : CGRectUnion(completeRect, selectionRect.rect);
	}
	return completeRect;
}

- (void)enumerateThroughParagraphsInRange:(NSRange)range withBlock:(void (^)(NSRange paragraphRange))block {
	NSArray *rangeOfParagraphsInSelectedText = [self.attributedText rangeOfParagraphsFromTextRange:self.selectedRange];
	for (int i = 0; i < rangeOfParagraphsInSelectedText.count; i++) {
		NSValue *value = rangeOfParagraphsInSelectedText[i];
		NSRange paragraphRange = value.rangeValue;
		block(paragraphRange);
	}
	NSRange fullRange = [self fullRangeFromArrayOfParagraphRanges:rangeOfParagraphsInSelectedText];
	self.selectedRange = fullRange;
}

- (void)updateToolbarState {
	// If no text exists or typing attributes is in progress update toolbar using typing attributes instead of selected text
	if (self.typingAttributesInProgress || !self.hasText) {
		[self.toolBar updateStateWithAttributes:self.typingAttributes];
	}
	else {
		NSInteger location = 0;
		if (self.selectedRange.location != NSNotFound) {
			location = (self.selectedRange.length == 0) ? MAX((int)self.selectedRange.location - 1, 0)
                                                        : (int)self.selectedRange.location;
		}
		NSDictionary *attributes = [self.attributedText attributesAtIndex:location effectiveRange:nil];
		[self.toolBar updateStateWithAttributes:attributes];
	}
}

- (NSRange)fullRangeFromArrayOfParagraphRanges:(NSArray *)paragraphRanges {
	if (!paragraphRanges.count) {
		return NSMakeRange(0, 0);
	}
	NSRange firstRange = [paragraphRanges.firstObject rangeValue];
	NSRange lastRange = [paragraphRanges.lastObject rangeValue];
	return NSMakeRange(firstRange.location, lastRange.location + lastRange.length - firstRange.location);
}

- (UIFont *)fontAtIndex:(NSInteger)index {
    return [[self dictionaryAtIndex:index] objectForKey:NSFontAttributeName];
}

- (NSDictionary *)dictionaryAtIndex:(NSInteger)index {
	if (!self.hasText || index == self.attributedText.string.length) {
        return self.typingAttributes; // end of string, use whatever we're currently using
	}
	else {
        return [self.attributedText attributesAtIndex:index effectiveRange:nil];
	}
}

- (void)applyAttributeToTypingAttribute:(id)attribute forKey:(NSString *)key {
	NSMutableDictionary *dictionary = [self.typingAttributes mutableCopy];
	[dictionary setObject:attribute forKey:key];
	self.typingAttributes = dictionary;
}

- (void)applyAttributes:(id)attribute forKey:(NSString *)key atRange:(NSRange)range {
	// If any text selected apply attributes to text
	if (range.length > 0) {
        // Workaround for when there is only one paragraph,
		// sometimes the attributedString is actually longer by one then the displayed text,
		// and this results in not being able to set to lef align anymore.
		if (range.length == self.textStorage.length - 1 && range.length == self.text.length) {
            ++range.length;
		}
		[self.textStorage addAttributes:[NSDictionary dictionaryWithObject:attribute forKey:key] range:range];
		if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"8.0")) {
            [self setSelectedRange:range];
			self.selectedRange = range;
		}
	}
	// If no text is selected apply attributes to typingAttribute
	else {
		self.typingAttributesInProgress = YES;
		[self applyAttributeToTypingAttribute:attribute forKey:key];
	}
	[self updateToolbarState];
}

- (void)removeAttributeForKey:(NSString *)key atRange:(NSRange)range {
	NSRange initialRange = self.selectedRange;
	[self.textStorage removeAttribute:key range:range];
	self.selectedRange = initialRange;
}

- (void)removeAttributeForKeyFromSelectedRange:(NSString *)key {
	[self removeAttributeForKey:key atRange:self.selectedRange];
}

- (void)applyAttributesToSelectedRange:(id)attribute forKey:(NSString *)key {
	[self applyAttributes:attribute forKey:key atRange:self.selectedRange];
}

- (void)applyFontAttributesToSelectedRangeWithBoldTrait:(NSNumber *)isBold italicTrait:(NSNumber *)isItalic fontName:(NSString *)fontName fontSize:(NSNumber *)fontSize {
	[self applyFontAttributesWithBoldTrait:isBold italicTrait:isItalic fontName:fontName fontSize:fontSize toTextAtRange:self.selectedRange];
}

- (void)applyFontAttributesWithBoldTrait:(NSNumber *)isBold italicTrait:(NSNumber *)isItalic fontName:(NSString *)fontName fontSize:(NSNumber *)fontSize toTextAtRange:(NSRange)range {
	// If any text selected apply attributes to text
	if (range.length > 0) {
		[self.textStorage beginEditing];
		[self.textStorage enumerateAttributesInRange:range
											 options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
										  usingBlock:^(NSDictionary *dictionary, NSRange range, BOOL *stop){
											  
											  UIFont *newFont = [self fontwithBoldTrait:isBold
																			italicTrait:isItalic
																			   fontName:fontName
																			   fontSize:fontSize
																		 fromDictionary:dictionary];
											  
											  if (newFont)
												  [self.textStorage addAttributes:[NSDictionary dictionaryWithObject:newFont forKey:NSFontAttributeName] range:range];
										  }];
		[self.textStorage endEditing];
		self.selectedRange = range;
	}
	// If no text is selected apply attributes to typingAttribute
	else {
		self.typingAttributesInProgress = YES;
		UIFont *newFont = [self fontwithBoldTrait:isBold
									  italicTrait:isItalic
										 fontName:fontName
										 fontSize:fontSize
								   fromDictionary:self.typingAttributes];
		if (newFont) {
            [self applyAttributeToTypingAttribute:newFont forKey:NSFontAttributeName];
		}
	}
	[self updateToolbarState];
}

-(BOOL)hasSelection {
	return self.selectedRange.length > 0;
}

// By default, if this function is called with nothing selected, it will resize all text.
-(void)changeFontSizeWithOperation:(CGFloat(^)(CGFloat currFontSize))operation {
	[self.textStorage beginEditing];
	NSRange range = self.selectedRange;
	if (range.length == 0) {
		range = NSMakeRange(0, [self.textStorage length]);
	}
	[self.textStorage enumerateAttributesInRange:range
										 options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
									  usingBlock:^(NSDictionary *dictionary, NSRange range, BOOL *stop){
										  // Get current font size
										  UIFont *currFont = [dictionary objectForKey:NSFontAttributeName];
										  if (currFont) {
											  CGFloat currFontSize = currFont.pointSize;
											  
											  CGFloat nextFontSize = operation(currFontSize);
											  if ((currFontSize < nextFontSize && nextFontSize <= self.maxFontSize) || // sizing up
												  (currFontSize > nextFontSize && self.minFontSize <= nextFontSize)) { // sizing down
												  UIFont *newFont = [self fontwithBoldTrait:[NSNumber numberWithBool:[currFont isBold]]
																				italicTrait:[NSNumber numberWithBool:[currFont isItalic]]
																				   fontName:currFont.fontName
																				   fontSize:[NSNumber numberWithFloat:nextFontSize]
																			 fromDictionary:dictionary];
												  if (newFont) {
													  [self.textStorage addAttributes:[NSDictionary dictionaryWithObject:newFont forKey:NSFontAttributeName] range:range];
												  }
											  }
										  }
									  }];
	[self.textStorage endEditing];
	[self updateToolbarState];
}


- (void)decreaseFontSize {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeFontSize];
	if (self.selectedRange.length == 0) {
		NSMutableDictionary *typingAttributes = [self.typingAttributes mutableCopy];
		UIFont *font = [typingAttributes valueForKey:NSFontAttributeName];
		CGFloat nextFontSize = font.pointSize - self.fontSizeChangeAmount;
		if (nextFontSize < self.minFontSize) {
			nextFontSize = self.minFontSize;
		}
		UIFont *nextFont = [font fontWithSize:nextFontSize];
		[typingAttributes setValue:nextFont forKey:NSFontAttributeName];
		self.typingAttributes = typingAttributes;
	}
	else {
		[self changeFontSizeWithOperation:^CGFloat (CGFloat currFontSize) {
			return currFontSize - self.fontSizeChangeAmount;
		}];
		[self sendDelegateTVChanged]; // only send if the actual text changes -- if no text selected, no text has actually changed
	}
}

- (void)increaseFontSize {
	[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeFontSize];
	if (self.selectedRange.length == 0) {
		NSMutableDictionary *typingAttributes = [self.typingAttributes mutableCopy];
		UIFont *font = [typingAttributes valueForKey:NSFontAttributeName];
		CGFloat nextFontSize = font.pointSize + self.fontSizeChangeAmount;
		if (nextFontSize > self.maxFontSize) {
			nextFontSize = self.maxFontSize;
		}
		UIFont *nextFont = [font fontWithSize:nextFontSize];
		[typingAttributes setValue:nextFont forKey:NSFontAttributeName];
		self.typingAttributes = typingAttributes;
	}
	else {
		[self changeFontSizeWithOperation:^CGFloat (CGFloat currFontSize) {
			return currFontSize + self.fontSizeChangeAmount;
		}];
		[self sendDelegateTVChanged]; // only send if the actual text changes -- if no text selected, no text has actually changed
	}
}

// TODO: Fix this function. You can't create a font that isn't bold from a dictionary that has a bold attribute currently, since if you send isBold 0 [nil], it'll use the dictionary, which is bold!
// In other words, this function has logical errors.
// Returns a font with given attributes. For any missing parameter takes the attribute from a given dictionary
- (UIFont *)fontwithBoldTrait:(NSNumber *)isBold italicTrait:(NSNumber *)isItalic fontName:(NSString *)fontName fontSize:(NSNumber *)fontSize fromDictionary:(NSDictionary *)dictionary {
	UIFont *newFont = nil;
	UIFont *font = [dictionary objectForKey:NSFontAttributeName];
	BOOL newBold = (isBold) ? isBold.intValue : [font isBold];
	BOOL newItalic = (isItalic) ? isItalic.intValue : [font isItalic];
	CGFloat newFontSize = (fontSize) ? fontSize.floatValue : font.pointSize;
	if (fontName) {
		newFont = [UIFont fontWithName:fontName size:newFontSize boldTrait:newBold italicTrait:newItalic];
	}
	else {
		newFont = [font fontWithBoldTrait:newBold italicTrait:newItalic andSize:newFontSize];
	}
	return newFont;
}

- (CGRect)currentScreenBoundsDependOnOrientation {
    CGRect screenBounds = [UIScreen mainScreen].bounds ;
    CGFloat width = CGRectGetWidth(screenBounds)  ;
    CGFloat height = CGRectGetHeight(screenBounds) ;
    UIInterfaceOrientation interfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
    if (UIInterfaceOrientationIsPortrait(interfaceOrientation)) {
        screenBounds.size = CGSizeMake(width, height);
    }
	else if (UIInterfaceOrientationIsLandscape(interfaceOrientation)) {
        screenBounds.size = CGSizeMake(height, width);
    }
    return screenBounds;
}

- (void)applyBulletListIfApplicable {
	NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	if (rangeOfCurrentParagraph.location == 0) {
        return; // there isn't a previous paragraph, so forget it. The user isn't in a bulleted list.
	}
	NSRange rangeOfPreviousParagraph = [self.attributedText firstParagraphRangeFromTextRange:NSMakeRange(rangeOfCurrentParagraph.location-1, 0)];
    //NSLog(@"[RTE] Is the user in the bullet list? %d", self.userInBulletList);
    if (!self.inBulletedList) { // fixes issue with backspacing into bullet list adding a bullet
		BOOL currentParagraphHasBullet = [[self.attributedText.string substringFromIndex:rangeOfCurrentParagraph.location] hasPrefix:self.BULLET_STRING];
		BOOL previousParagraphHasBullet = [[self.attributedText.string substringFromIndex:rangeOfPreviousParagraph.location] hasPrefix:self.BULLET_STRING];
        BOOL isCurrParaBlank = [[self.attributedText.string substringWithRange:rangeOfCurrentParagraph] isEqualToString:@""];
        // if we don't check to see if the current paragraph is blank, bad bugs happen with
        // the current paragraph where the selected range doesn't let the user type O_o
        if (previousParagraphHasBullet && !currentParagraphHasBullet && isCurrParaBlank) {
            // Fix the indentation. Here is the use case for this code:
            /*
             ---
                • bullet
             
             |
             ---
             Where | is the cursor on a blank line. User hits backspace. Without fixing the 
             indentation, the cursor ends up indented at the same indentation as the bullet.
             */
            NSDictionary *dictionary = [self dictionaryAtIndex:rangeOfCurrentParagraph.location];
            NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
            paragraphStyle.firstLineHeadIndent = 0;
            paragraphStyle.headIndent = 0;
			[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:rangeOfCurrentParagraph];
			[self setIndentationWithAttributes:dictionary paragraphStyle:paragraphStyle atRange:rangeOfCurrentParagraph];
        }
        return;
    }
	if (rangeOfCurrentParagraph.length != 0) {
		return;
	}
	if (!self.justDeletedBackward &&
		[[self.attributedText.string substringFromIndex:rangeOfPreviousParagraph.location] hasPrefix:self.BULLET_STRING]) {
        [self richTextEditorToolbarDidSelectBulletListWithCaller:self];
	}
}

- (void)removeBulletIndentation:(NSRange)firstParagraphRange {
	NSRange rangeOfParagraph = [self.attributedText firstParagraphRangeFromTextRange:firstParagraphRange];
	NSDictionary *dictionary = [self dictionaryAtIndex:rangeOfParagraph.location];
	NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
	paragraphStyle.firstLineHeadIndent = 0;
	paragraphStyle.headIndent = 0;
	[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:rangeOfParagraph];
	[self setIndentationWithAttributes:dictionary paragraphStyle:paragraphStyle atRange:firstParagraphRange];
}

- (void)deleteBulletListWhenApplicable {
	NSRange range = self.selectedRange;
	if (range.location > 0) {
        NSString *checkString = self.BULLET_STRING;
		if ([checkString length] > 1) { // chop off last letter and use that
            checkString = [checkString substringToIndex:[checkString length]-1];
		}
        //else return;
        NSUInteger checkStringLength = [checkString length];
        if (![self.attributedText.string isEqualToString:self.BULLET_STRING]) {
            if (((int)(range.location - checkStringLength) >= 0 &&
                 [[self.attributedText.string substringFromIndex:range.location-checkStringLength] hasPrefix:checkString])) {
                NSLog(@"[RTE] Getting rid of a bullet due to backspace while in empty bullet paragraph.");
				// Get rid of bullet string
				[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeBullet];
				//NSLog(@"[RTE] Getting rid of a bullet due to backspace while in empty bullet paragraph.");
				// Get rid of bullet string
				[self.textStorage deleteCharactersInRange:NSMakeRange(range.location-checkStringLength, checkStringLength)];
				NSRange newRange = NSMakeRange(range.location-checkStringLength, 0);
				self.selectedRange = newRange;
				
				// Get rid of bullet indentation
				[self removeBulletIndentation:newRange];
            }
            else {
                // User may be needing to get out of a bulleted list due to hitting enter (return)
                NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
                NSInteger prevParaLocation = rangeOfCurrentParagraph.location-1;
				if (prevParaLocation >= 0) {
					NSRange rangeOfPreviousParagraph = [self.attributedText firstParagraphRangeFromTextRange:NSMakeRange(rangeOfCurrentParagraph.location - 1, 0)];
					// If the following if statement is true, the user hit enter on a blank bullet list
					// Basically, there is now a bullet ' ' \n bullet ' ' that we need to delete (' ' == space)
					// Since it gets here AFTER it adds a new bullet
					if ([[self.attributedText.string substringWithRange:rangeOfPreviousParagraph] hasSuffix:self.BULLET_STRING]) {
						[self sendDelegatePreviewChangeOfType:RichTextEditorPreviewChangeBullet];
						//NSLog(@"[RTE] Getting rid of bullets due to user hitting enter.");
						NSRange rangeToDelete = NSMakeRange(rangeOfPreviousParagraph.location, rangeOfPreviousParagraph.length+rangeOfCurrentParagraph.length + 1);
						[self.textStorage deleteCharactersInRange:rangeToDelete];
						NSRange newRange = NSMakeRange(rangeOfPreviousParagraph.location, 0);
						self.selectedRange = newRange;
						// Get rid of bullet indentation
						[self removeBulletIndentation:newRange];
					}
                }
            }
        }
	}
}

#pragma mark - RichTextEditorToolbarDataSource Methods -

- (NSArray *)fontFamilySelectionForRichTextEditorToolbar {
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(fontFamilySelectionForRichTextEditor:)]) {
		return [self.dataSource fontFamilySelectionForRichTextEditor:self];
	}
	return nil;
}

- (NSArray *)fontSizeSelectionForRichTextEditorToolbar {
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(fontSizeSelectionForRichTextEditor:)]) {
		return [self.dataSource fontSizeSelectionForRichTextEditor:self];
	}
	return nil;
}

- (RichTextEditorToolbarPresentationStyle)presentationStyleForRichTextEditorToolbar {
	BOOL isUsingiPad = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(presentationStyleForRichTextEditor:)]) {
		RichTextEditorToolbarPresentationStyle style = [self.dataSource presentationStyleForRichTextEditor:self];
		if (!isUsingiPad && style == RichTextEditorToolbarPresentationStylePopover) {
			return RichTextEditorToolbarPresentationStyleModal;
		}
		else {
			return style;
		}
	}
	return isUsingiPad ? RichTextEditorToolbarPresentationStylePopover : RichTextEditorToolbarPresentationStyleModal;
}

- (UIModalPresentationStyle)modalPresentationStyleForRichTextEditorToolbar {
	BOOL isUsingiPad = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(modalPresentationStyleForRichTextEditor:)]) {
		return [self.dataSource modalPresentationStyleForRichTextEditor:self];
	}
	return isUsingiPad ? UIModalPresentationFormSheet : UIModalPresentationFullScreen;
}

- (UIModalTransitionStyle)modalTransitionStyleForRichTextEditorToolbar {
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(modalTransitionStyleForRichTextEditor:)]) {
		return [self.dataSource modalTransitionStyleForRichTextEditor:self];
	}
	return UIModalTransitionStyleCoverVertical;
}

- (RichTextEditorFeature)featuresEnabledForRichTextEditorToolbar {
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(featuresEnabledForRichTextEditor:)]){
		return [self.dataSource featuresEnabledForRichTextEditor:self];
	}
	return RichTextEditorFeatureAll;
}

- (UIViewController *)firstAvailableViewControllerForRichTextEditorToolbar {
	return [self firstAvailableViewController];
}

+ (NSString *)convertPreviewChangeTypeToString:(RichTextEditorPreviewChange)changeType withNonSpecialChangeText:(BOOL)shouldReturnStringForNonSpecialType {
	switch (changeType) {
		case RichTextEditorPreviewChangeBold:
			return NSLocalizedString(@"Bold", @"");
		case RichTextEditorPreviewChangeCut:
			return NSLocalizedString(@"Cut", @"");
		case RichTextEditorPreviewChangePaste:
			return NSLocalizedString(@"Paste", @"");
		case RichTextEditorPreviewChangeBullet:
			return NSLocalizedString(@"Bulleted List", @"");
		case RichTextEditorPreviewChangeItalic:
			return NSLocalizedString(@"Italic", @"");
		case RichTextEditorPreviewChangeFontResize:
		case RichTextEditorPreviewChangeFontSize:
			return NSLocalizedString(@"Font Resize", @"");
		case RichTextEditorPreviewChangeFontName:
			return NSLocalizedString(@"Font Name", @"");
		case RichTextEditorPreviewChangeFontColor:
			return NSLocalizedString(@"Font Color", @"");
		case RichTextEditorPreviewChangeHighlight:
			return NSLocalizedString(@"Text Highlight", @"");
		case RichTextEditorPreviewChangePageBreak:
			return NSLocalizedString(@"Insert Page Break", @"");
		case RichTextEditorPreviewChangeUnderline:
			return NSLocalizedString(@"Underline", @"");
		case RichTextEditorPreviewChangeStrikethrough:
			return NSLocalizedString(@"Strikethrough", @"");
		case RichTextEditorPreviewChangeIndentDecrease:
		case RichTextEditorPreviewChangeIndentIncrease:
			return NSLocalizedString(@"Text Indent", @"");
		case RichTextEditorPreviewChangeParagraphFirstLineHeadIndent:
			return NSLocalizedString(@"First Line Head Indent", @"");
		case RichTextEditorPreviewChangeTextAlignment:
			return NSLocalizedString(@"Text Alignment", @"");
		case RichTextEditorPreviewChangeTextAttachment:
			return NSLocalizedString(@"Text Attachment", @"");
		case RichTextEditorPreviewChangeKeyDown:
			if (shouldReturnStringForNonSpecialType)
				return NSLocalizedString(@"Key Down", @"");
		case RichTextEditorPreviewChangeEnter:
			if (shouldReturnStringForNonSpecialType)
				return NSLocalizedString(@"Enter [Return] Key", @"");
		case RichTextEditorPreviewChangeSpace:
			if (shouldReturnStringForNonSpecialType)
				return NSLocalizedString(@"Space", @"");
		case RichTextEditorPreviewChangeDelete:
			if (shouldReturnStringForNonSpecialType)
				return NSLocalizedString(@"Delete", @"");
		case RichTextEditorPreviewChangeArrowKey:
			if (shouldReturnStringForNonSpecialType)
				return NSLocalizedString(@"Arrow Key Movement", @"");
		case RichTextEditorPreviewChangeMouseDown:
			if (shouldReturnStringForNonSpecialType)
				return NSLocalizedString(@"Mouse Down", @"");
		default:
			break;
	}
	return @"";
}

#pragma mark - Keyboard Shortcuts
/*
- (NSArray *)keyCommands {
    return @[[UIKeyCommand keyCommandWithInput:@"B" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
			 [UIKeyCommand keyCommandWithInput:@"b" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
			 [UIKeyCommand keyCommandWithInput:@"I" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
             [UIKeyCommand keyCommandWithInput:@"i" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
			 [UIKeyCommand keyCommandWithInput:@"U" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
			 [UIKeyCommand keyCommandWithInput:@"u" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
			 [UIKeyCommand keyCommandWithInput:@"T" modifierFlags:UIKeyModifierCommand|UIKeyModifierShift action:@selector(keyboardKeyPressed:)],
			 [UIKeyCommand keyCommandWithInput:@"t" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
             ];
}

- (void)keyboardKeyPressed:(UIKeyCommand*)keyCommand {
    switch ([keyCommand.input UTF8String][0]) {
		case 'B':
		case 'b':
            [self richTextEditorToolbarDidSelectBold];
            break;
		case 'I':
        case 'i':
            [self richTextEditorToolbarDidSelectItalic];
            break;
		case 'U':
        case 'u':
            [self richTextEditorToolbarDidSelectUnderline];
            break;
		case 'T':
			[self richTextEditorToolbarDidSelectParagraphIndentation:ParagraphIndentationDecrease];
			break;
		case 't':
			[self richTextEditorToolbarDidSelectParagraphIndentation:ParagraphIndentationIncrease];
			break;
        default:
            break;
    }
}*/

@end
