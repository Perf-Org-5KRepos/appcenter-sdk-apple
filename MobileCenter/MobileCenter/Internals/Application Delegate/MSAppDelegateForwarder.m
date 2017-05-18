#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#import "MSAppDelegateForwarderPrivate.h"
#import "MSAppDelegate.h"
#import "MSLogger.h"
#import "MSMobileCenterInternal.h"
#import "MSUtility+Application.h"

static NSString *const kMSReturnedValueSelectorPart = @"returnedValue:";
static NSString *const kMSIsSwizzlingEnabledKey = @"MSAppDelegateForwarderEnabled";

static NSHashTable<id<MSAppDelegate>> *_delegates = nil;
static NSMutableSet<NSString *> *_selectorsToSwizzle = nil;
static NSMutableDictionary<NSString *, NSValue *> *_originalImplementations = nil;
static NSMutableArray<dispatch_block_t> *_traceBuffer = nil;
static IMP _originalSetDelegateImp = NULL;
static BOOL _enabled = YES;

@implementation MSAppDelegateForwarder

+ (instancetype)sharedInstance {
  static MSAppDelegateForwarder *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [self new];
  });
  return sharedInstance;
}

#pragma mark - Accessors

+ (NSHashTable<id<MSAppDelegate>> *)delegates {
  return _delegates ?: (_delegates = [NSHashTable weakObjectsHashTable]);
}

+ (void)setDelegates:(NSHashTable<id<MSAppDelegate>> *)delegates {
  _delegates = delegates;
}

+ (NSMutableSet<NSString *> *)selectorsToSwizzle {
  return _selectorsToSwizzle ?: (_selectorsToSwizzle = [NSMutableSet new]);
}

+ (NSMutableDictionary<NSString *, NSValue *> *)originalImplementations {
  return _originalImplementations ?: (_originalImplementations = [NSMutableDictionary new]);
}

+ (NSMutableArray<dispatch_block_t> *)traceBuffer {
  return _traceBuffer ?: (_traceBuffer = [NSMutableArray new]);
}

+ (IMP)originalSetDelegateImp {
  return _originalSetDelegateImp;
}

+ (void)setOriginalSetDelegateImp:(IMP)originalSetDelegateImp {
  _originalSetDelegateImp = originalSetDelegateImp;
}

+ (BOOL)enabled {
  @synchronized(self) {
    return _enabled;
  }
}

+ (void)setEnabled:(BOOL)enabled {
  @synchronized(self) {
    _enabled = enabled;
    if (!enabled) {
      [self.delegates removeAllObjects];
    }
  }
}

#pragma mark - Delegates

+ (void)addDelegate:(id<MSAppDelegate>)delegate {
  @synchronized(self) {
    if (self.enabled) {
      [self.delegates addObject:delegate];
    }
  }
}

+ (void)removeDelegate:(id<MSAppDelegate>)delegate {
  @synchronized(self) {
    if (self.enabled) {
      [self.delegates removeObject:delegate];
    }
  }
}

#pragma mark - Swizzling

+ (void)swizzleOriginalDelegate:(id<UIApplicationDelegate>)originalDelegate {
  IMP originalImp = NULL;
  Class delegateClass = [originalDelegate class];
  SEL selector;

  // Swizzle all registered selectors.
  for (NSString *selectorString in self.selectorsToSwizzle) {

    // The same selector is used on both forwarder and delegate.
    selector = NSSelectorFromString(selectorString);
    originalImp = [self swizzleOriginalSelector:selector withCustomSelector:selector originalClass:delegateClass];
    if (originalImp) {

      // Save the original implementation for later use.
      MSAppDelegateForwarder.originalImplementations[selectorString] =
          [NSValue valueWithBytes:&originalImp objCType:@encode(IMP)];
    }
  }
  [self.selectorsToSwizzle removeAllObjects];
}

+ (IMP)swizzleOriginalSelector:(SEL)originalSelector
            withCustomSelector:(SEL)customSelector
                 originalClass:(Class)originalClass {

  // Replace original implementation
  NSString *originalSelectorString = NSStringFromSelector(originalSelector);
  Method originalMethod = class_getInstanceMethod(originalClass, originalSelector);
  IMP customImp = class_getMethodImplementation(self, customSelector);
  IMP originalImp = NULL;
  BOOL methodAdded = NO;

  // Replace original implementation by the custom one.
  if (originalMethod) {
    originalImp = method_setImplementation(originalMethod, customImp);
  } else if (![originalClass instancesRespondToSelector:originalSelector]) {

    /*
     * The original class may not implement the selector (e.g.: optional method from protocol),
     * add the method to the original class and associate it with the custom implementation.
     */
    Method customMethod = class_getInstanceMethod(self, customSelector);
    methodAdded = class_addMethod(originalClass, originalSelector, customImp, method_getTypeEncoding(customMethod));
  }

  /*
   * If class instances respond to the selector but no implementation is found it's likely that the original class
   * is doing message forwarding, in this case we can't add our implementation to the class or we will break the
   * forwarding.
   */

  // Validate swizzling.
  if (!originalImp && !methodAdded) {
    [self.traceBuffer addObject:^{
      MSLogError([MSMobileCenter logTag],
               @"Cannot swizzle selector '%@' of class '%@'. You will have to explicitly call APIs from "
               @"Mobile Center in your app delegate implementation.",
               originalSelectorString, originalClass);
    }];
  } else {
    [self.traceBuffer addObject:^{
      MSLogDebug([MSMobileCenter logTag], @"Selector '%@' of class '%@' is swizzled.", originalSelectorString, originalClass);
    }];
  }
  return originalImp;
}

+ (void)addAppDelegateSelectorToSwizzle:(SEL)selector {
  [self.selectorsToSwizzle addObject:NSStringFromSelector(selector)];
}

#pragma mark - UIApplication

- (void)customSetDelegate:(id<UIApplicationDelegate>)delegate {

  // Swizzle only once.
  static dispatch_once_t swizzleOnceToken;
  dispatch_once(&swizzleOnceToken, ^{

    // Swizzle the app delegate before it's actually set.
    [MSAppDelegateForwarder swizzleOriginalDelegate:delegate];
  });

  // Forward to the original `setDelegate:` implementation.
  IMP originalImp = MSAppDelegateForwarder.originalSetDelegateImp;
  if (originalImp) {
    ((void (*)(id, SEL, id<UIApplicationDelegate>))originalImp)(self, _cmd, delegate);
  }
}

#pragma mark - UIApplicationDelegate

/*
 * Those methods will never get called but their implementation will be used by swizzling.
 * Those implementations will run within the delegate context. Meaning that `self` will point
 * to the original app delegate and not this forwarder.
 */

- (BOOL)application:(UIApplication *)app
              openURL:(NSURL *)url
    sourceApplication:(nullable NSString *)sourceApplication
           annotation:(id)annotation {
  BOOL result = NO;
  IMP originalImp = NULL;

  // Forward to the original delegate.
  [MSAppDelegateForwarder.originalImplementations[NSStringFromSelector(_cmd)] getValue:&originalImp];
  if (originalImp) {
    result = ((BOOL(*)(id, SEL, UIApplication *, NSURL *, NSString *, id))originalImp)(self, _cmd, app, url,
                                                                                       sourceApplication, annotation);
  }

  // Forward to custom delegates.
  return [[MSAppDelegateForwarder sharedInstance] application:app
                                                      openURL:url
                                            sourceApplication:sourceApplication
                                                   annotation:annotation
                                                returnedValue:result];
}

- (BOOL)application:(UIApplication *)app
            openURL:(nonnull NSURL *)url
            options:(nonnull NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
  BOOL result = NO;
  IMP originalImp = NULL;

  // Forward to the original delegate.
  [MSAppDelegateForwarder.originalImplementations[NSStringFromSelector(_cmd)] getValue:&originalImp];
  if (originalImp) {
    result = ((BOOL(*)(id, SEL, UIApplication *, NSURL *,
                       NSDictionary<UIApplicationOpenURLOptionsKey, id> *))originalImp)(self, _cmd, app, url, options);
  }

  // Forward to custom delegates.
  return [[MSAppDelegateForwarder sharedInstance] application:app openURL:url options:options returnedValue:result];
}

#pragma mark - Forwarding

- (void)forwardInvocation:(NSInvocation *)invocation {
  @synchronized([self class]) {
    BOOL forwarded = NO;

    // Returned value argument is always the last one.
    NSUInteger returnedValueIdx = invocation.methodSignature.numberOfArguments - 1;
    void *returnedValuePtr = malloc(invocation.methodSignature.methodReturnLength);

    // Forward to delegates executing a custom method.
    for (id<MSAppDelegate> delegate in [self class].delegates) {
      if ([delegate respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:delegate];

        // Chaining return values.
        [invocation getReturnValue:returnedValuePtr];
        [invocation setArgument:returnedValuePtr atIndex:returnedValueIdx];
        forwarded = YES;
      }
    }

    // Forward back the original return value if no delegates to receive the message.
    if (!forwarded) {
      [invocation getArgument:returnedValuePtr atIndex:returnedValueIdx];
      [invocation setReturnValue:returnedValuePtr];
    }
    free(returnedValuePtr);
  }
}

#pragma mark - Logging

+ (void)flushTraceBuffer{
  
  // Only trace once.
  static dispatch_once_t traceOnceToken;
  dispatch_once(&traceOnceToken, ^{
    for (dispatch_block_t traceBlock in self.traceBuffer){
      traceBlock();
    }
    [self.traceBuffer removeAllObjects];
  });
}

@end

/*
 * The application starts querying its delegate for its implementation as soon as it is set then may never query again.
 * It means that if the application delegate doesn't implement an optional method of the `UIApplicationDelegate`
 * protocol at that time then that method may never be called even if added later via swizzling. This is why the
 * application delegate swizzling should happen at the time it is set to the application object.
 */

@implementation UIApplication (MSSwizzling)

+ (void)load {
  NSDictionary *swizzlingEnabledNum = [[NSBundle mainBundle] objectForInfoDictionaryKey:kMSIsSwizzlingEnabledKey];
  BOOL swizzlingEnabled = swizzlingEnabledNum ? [((NSNumber *)swizzlingEnabledNum)boolValue] : YES;
  MSAppDelegateForwarder.enabled = swizzlingEnabled;

  // Swizzle `setDelegate:` of class `UIApplication`.
  if (swizzlingEnabled) {
    [MSAppDelegateForwarder.traceBuffer addObject:^{
      MSLogDebug([MSMobileCenter logTag], @"Swizzling enabled.");
    }];
    MSAppDelegateForwarder.originalSetDelegateImp =
        [MSAppDelegateForwarder swizzleOriginalSelector:@selector(setDelegate:)
                                     withCustomSelector:@selector(customSetDelegate:)
                                          originalClass:[UIApplication class]];
  } else {
    [MSAppDelegateForwarder.traceBuffer addObject:^{
      MSLogDebug([MSMobileCenter logTag], @"Swizzling disabled.");
    }];
  }
}

@end
