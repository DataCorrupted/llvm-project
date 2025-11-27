// Test backward compatibility - direct methods without the flag should keep old behavior
// RUN: %clang_cc1 -emit-llvm -fobjc-arc -triple arm64-apple-darwin10 %s -o - | FileCheck %s

@interface MyClass
- (int)directMethod __attribute__((objc_direct));
@end

@implementation MyClass

// Without the flag, should use hidden symbol with \01 prefix
// CHECK-LABEL: define hidden {{.*}} @"\01-[MyClass directMethod]"(
- (int)directMethod {
  // Should have nil check in implementation
  // CHECK: icmp eq ptr {{.*}}, null
  // CHECK: objc_direct_method.self_is_nil
  return 42;
}

@end
