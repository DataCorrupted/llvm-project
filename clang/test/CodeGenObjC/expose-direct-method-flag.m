// Test that the -fobjc-expose-direct-methods flag is recognized and sets the CodeGen option
// RUN: %clang_cc1 -emit-llvm -triple arm64-apple-darwin10 -fobjc-expose-direct-methods %s -o -
// RUN: %clang_cc1 -emit-llvm -triple arm64-apple-darwin10 %s -o -

@interface MyClass
- (int)directMethod __attribute__((objc_direct));
@end

@implementation MyClass
- (int)directMethod {
  return 42;
}
@end

// WITH-FLAG: Test will be extended in Phase 1 to verify symbol exposure
// WITHOUT-FLAG: Test will be extended in Phase 1 to verify backward compatibility
