//
//  KcScrollViewTool.m
//  KcDebugTool
//
//  Created by 张杰 on 2021/4/16.
//

#import "KcScrollViewTool.h"

@interface KcScrollViewTool () <UIGestureRecognizerDelegate>

@property (nonatomic) UIPanGestureRecognizer *panGestureRecognizer;
/// 点击 - 结束编辑
@property (nonatomic) UITapGestureRecognizer *tapEndEditing;

@end

@implementation KcScrollViewTool

#pragma mark - public

- (void)setEnableScrolled:(BOOL)enableScrolled {
    _enableScrolled = enableScrolled;
    
    self.panGestureRecognizer.enabled = enableScrolled;
}

- (void)setShouldTapEndEditing:(BOOL)shouldTapEndEditing {
    _shouldTapEndEditing = shouldTapEndEditing;
    
    self.tapEndEditing.enabled = shouldTapEndEditing;
}

- (void)setView:(UIView *)view {
    _view = view;
    
    [view addGestureRecognizer:self.panGestureRecognizer];
    [view addGestureRecognizer:self.tapEndEditing];
}

#pragma mark - event

- (void)updatePosition {
    CGPoint point = [self.panGestureRecognizer translationInView:self.view];
    
    CGSize maxSize = CGSizeMake(CGRectGetWidth(UIScreen.mainScreen.bounds) - CGRectGetWidth(self.view.frame),
                                CGRectGetHeight(UIScreen.mainScreen.bounds) - CGRectGetHeight(self.view.frame));
    CGPoint currentWindowPoint = self.view.frame.origin;
    
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
    
    self.view.frame = CGRectMake(x, y, CGRectGetWidth(self.view.frame), CGRectGetHeight(self.view.frame));
    
    [self.panGestureRecognizer setTranslation:CGPointZero inView:self.view];
}

- (void)didEndEditing {
    [self.view endEditing:YES];
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
        _tapEndEditing.enabled = false;
    }
    return _tapEndEditing;
}

@end
