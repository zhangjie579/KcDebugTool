//
//  KcFloatingWindow.m
//  OCTest
//
//  Created by samzjzhang on 2020/4/28.
//  Copyright © 2020 samzjzhang. All rights reserved.
//

#import "KcFloatingWindow.h"

@interface KcFloatingWindow () <UIGestureRecognizerDelegate>

@property (nonatomic) UIPanGestureRecognizer *panGestureRecognizer;
/// 点击 - 结束编辑
@property (nonatomic) UITapGestureRecognizer *tapEndEditing;

@end

@implementation KcFloatingWindow

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        [self setup];
    }
    return self;
}

#pragma mark - public

- (void)setEnableScrolled:(BOOL)enableScrolled {
    _enableScrolled = enableScrolled;
    
    self.panGestureRecognizer.enabled = enableScrolled;
}

- (void)setShouldTapEndEditing:(BOOL)shouldTapEndEditing {
    _shouldTapEndEditing = shouldTapEndEditing;
    
    self.tapEndEditing.enabled = shouldTapEndEditing;
}

#pragma mark - event

- (void)updatePosition {
    CGPoint point = [self.panGestureRecognizer translationInView:self];
    
    CGSize maxSize = CGSizeMake(CGRectGetWidth(UIScreen.mainScreen.bounds) - CGRectGetWidth(self.frame),
                                CGRectGetHeight(UIScreen.mainScreen.bounds) - CGRectGetHeight(self.frame));
    CGPoint currentWindowPoint = self.frame.origin;
    
    CGFloat x = currentWindowPoint.x + point.x;
    CGFloat y = currentWindowPoint.y + point.y;
    
    if (x < 0) {
        x = 0;
    } else if (x > maxSize.width) {
        x = maxSize.width;
    }
    
    if (y < 0) {
        y = 0;
    } else if (y > maxSize.height) {
        y = maxSize.height;
    }
    
    self.frame = CGRectMake(x, y, CGRectGetWidth(self.frame), CGRectGetHeight(self.frame));
    
    [self.panGestureRecognizer setTranslation:CGPointZero inView:self];
}

- (void)didEndEditing {
    [self endEditing:YES];
}

#pragma mark - delegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (self.shouldReceiveTouch) {
        return self.shouldReceiveTouch(gestureRecognizer, touch);
    }
    return true;
}

#pragma mark - private

- (void)setup {
    {
        self.enableScrolled = YES;
        self.shouldTapEndEditing = false;
    }
    {
        self.backgroundColor = UIColor.clearColor;
        self.windowLevel = NSIntegerMax;
        self.hidden = NO;
    }
    
    [self addGestureRecognizer:self.panGestureRecognizer];
    [self addGestureRecognizer:self.tapEndEditing];
}

#pragma mark - 懒加载

- (UIPanGestureRecognizer *)panGestureRecognizer {
    if (!_panGestureRecognizer) {
        _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(updatePosition)];
    }
    return _panGestureRecognizer;
}

- (UITapGestureRecognizer *)tapEndEditing {
    if (!_tapEndEditing) {
        _tapEndEditing = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didEndEditing)];
        _tapEndEditing.delegate = self;
    }
    return _tapEndEditing;
}

@end
