#import "system_headers.h"
@implementation TestClass : NSObject {
}
+ (void)classSelector {
}
- (void)instanceSelector {
}
- (int)answer {
  return 42;
}
@end

int test_RespondsToSelector(void) {
  TestClass *instance = [TestClass new];
  SEL instance_sel =
      NSSelectorFromString([NSString stringWithUTF8String:"instanceSelector"]);
  SEL class_sel =
      NSSelectorFromString([NSString stringWithUTF8String:"classSelector"]);
  if (![instance respondsToSelector:instance_sel] ||
      [instance respondsToSelector:class_sel]) {
    return -1;
  }
  if ([TestClass respondsToSelector:instance_sel] ||
      ![TestClass respondsToSelector:class_sel]) {
    return -2;
  }
  return 0;
}

// Method is opaque. In touchHLE, as in iPhone OS 3, this is its layout. On
// macOS, methods can be stored more compactly, so the runtime's accessors are
// used there instead.
struct method_layout {
  SEL name;
  const char *types;
  void *imp;
};

static SEL test_method_name(Method method) {
#ifdef DEFINE_ME_WHEN_BUILDING_ON_MACOS
  return method_getName(method);
#else
  return ((struct method_layout *)method)->name;
#endif
}

static void *test_method_imp(Method method) {
#ifdef DEFINE_ME_WHEN_BUILDING_ON_MACOS
  return (void *)method_getImplementation(method);
#else
  return ((struct method_layout *)method)->imp;
#endif
}

int test_class_getInstanceMethod(void) {
  TestClass *instance = [TestClass new];
  SEL answer_sel =
      NSSelectorFromString([NSString stringWithUTF8String:"answer"]);
  Method method = class_getInstanceMethod([TestClass class], answer_sel);
  if (method == 0 || test_method_name(method) != answer_sel) {
    return -1;
  }
  if (((int (*)(id, SEL))test_method_imp(method))(instance, answer_sel) != 42) {
    return -2;
  }
  if (class_getInstanceMethod([TestClass class], answer_sel) != method) {
    return -3;
  }
  // Class methods aren't instance methods.
  SEL class_sel =
      NSSelectorFromString([NSString stringWithUTF8String:"classSelector"]);
  if (class_getInstanceMethod([TestClass class], class_sel) != 0) {
    return -4;
  }
  // Inherited from touchHLE's NSObject.
  SEL retain_count_sel =
      NSSelectorFromString([NSString stringWithUTF8String:"retainCount"]);
  // (A typedef, because clang-format versions disagree on how to space the
  // cast.)
  typedef NSUInteger (*retain_count_imp)(id, SEL);
  Method inherited =
      class_getInstanceMethod([TestClass class], retain_count_sel);
  if (inherited == 0 || ((retain_count_imp)test_method_imp(inherited))(
                            instance, retain_count_sel) != 1) {
    return -5;
  }
  [instance release];
  return 0;
}
