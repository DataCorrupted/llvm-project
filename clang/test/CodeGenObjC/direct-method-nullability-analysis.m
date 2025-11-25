// RUN: %clang_cc1 -emit-llvm -fobjc-arc -fobjc-nil-check-thunk -triple x86_64-apple-darwin10 %s -o - | FileCheck %s

// This test verifies that nullability analysis is working correctly.
// Once Phase 4 is implemented, this will test that:
// - _Nonnull receivers call the implementation directly
// - Nullable receivers call through thunks
// - 'self' in instance methods is treated as non-null

__attribute__((objc_root_class))
@interface Root
- (int)directMethod __attribute__((objc_direct));
+ (int)classDirectMethod __attribute__((objc_direct));
- (int)directMethodFromNonnull:(Root * _Nonnull)receiver;
- (int)directMethodFromNullable:(Root * _Nullable)receiver;
- (int)directMethodFromSelf;
@end

@implementation Root

- (int)directMethod __attribute__((objc_direct)) {
  return 42;
}

+ (int)classDirectMethod __attribute__((objc_direct)) {
  return 100;
}

// Test 1: _Nonnull receiver should eventually call implementation directly
// CHECK-LABEL: define{{.*}} i32 @"\01-[Root directMethodFromNonnull:]"
- (int)directMethodFromNonnull:(Root * _Nonnull)receiver {
  // TODO Phase 4: This should call @"-[Root directMethod]" directly (no thunk)
  // CHECK: call i32 @"-[Root directMethod]"
  return [receiver directMethod];
}

// Test 2: _Nullable receiver should eventually call through thunk
// CHECK-LABEL: define{{.*}} i32 @"\01-[Root directMethodFromNullable:]"
- (int)directMethodFromNullable:(Root * _Nullable)receiver {
  // TODO Phase 4: This should call @"-[Root directMethod]_thunk"
  // For now, it just calls the direct implementation
  return [receiver directMethod];
}

// Test 3: 'self' is treated as non-null in instance methods
// CHECK-LABEL: define{{.*}} i32 @"\01-[Root directMethodFromSelf]"
- (int)directMethodFromSelf {
  // TODO Phase 4: This should call @"-[Root directMethod]" directly (no thunk)
  // because 'self' is known to be non-null in instance methods
  return [self directMethod];
}

@end

// Test 4: Class type receivers (always non-null)
// CHECK-LABEL: define{{.*}} i32 @testClassReceiver()
int testClassReceiver() {
  // TODO Phase 4: Class objects are never nil, should call directly
  return [Root classDirectMethod];
}
