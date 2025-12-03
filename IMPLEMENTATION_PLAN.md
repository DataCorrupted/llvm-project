# Implementation Plan: ObjC Direct Method Nil-Check Thunk Optimization
  # Analyze code size with Bloaty
  bloaty without_opt -- with_opt

  # Expected: 5-15% code size reduction for apps with many direct methods
```

**Measure Performance**:
```bash
# Run performance benchmarks on Darwin
# Test message send throughput

# Benchmark: Non-null receiver calls (should be faster - direct to impl)
# Benchmark: Nullable receiver calls (should use thunk, minimal overhead)
# Benchmark: Variadic methods (inline nil check, should be comparable)

# Expected: No performance regression, potential improvement for non-null paths
```

#### 5.6: Integration Tests

**Complete test coverage combining multiple aspects**:
- ARC + struct returns + nil receivers
- Cross-TU calls + variadic methods
- Weak-linked classes + properties
- Category methods + class methods

**Validation Commands**:
```bash
# Run all new Darwin-specific executable tests
cd clang/test/CodeGenObjC-Darwin
./run-darwin-tests.sh

# Expected: All tests pass
```

---

## Table of Contents

1. [Background and Motivation](#background-and-motivation)
2. [Design Overview](#design-overview)
3. [Implementation Phases](#implementation-phases)
4. [Files to Modify](#files-to-modify)
5. [Testing Strategy](#testing-strategy)
6. [Build and Validation](#build-and-validation)

---

## Background and Motivation

### What is `objc_direct`?

The `__attribute__((objc_direct))` attribute in Objective-C allows methods to bypass the Objective-C message dispatch system and use direct function calls instead. This improves performance but was originally designed with an emphasis on ABI stability that led to several drawbacks.

### Current Problems

The existing implementation of `objc_direct` has three main issues:

**1. Code Bloat and Poor Optimization**
- Every direct method implementation contains nil-checking logic
- This nil check is duplicated even at call sites where the receiver is provably non-null (like `self`)
- For instance methods: `if (self == nil) return <zero-value>;`
- For class methods: includes both class realization and nil checks for weak-linked classes
- This redundant checking significantly increases binary size

**2. Poor Linkage**
- Direct methods use hidden symbols (internal linkage)
- This prevents calling direct methods from other translation units (link units)
- Developers must manually write wrapper thunks to expose methods, further increasing code size
- Example: A method `-[MyClass method]` is emitted as `@"\01-[MyClass method]"` with hidden visibility

**3. Swift Interop Complexity**
- Swift functions cannot be easily exposed as `@objcDirect`
- The Swift frontend (SILGen) faces significant implementation challenges
- When a direct method needs nil checking, Swift must handle `Optional<MyClass>` unwrapping before calling
- This complexity makes bridging Swift to Objective-C direct methods difficult

### Proposed Solution Benefits

By moving nil checks from implementations to caller-side thunks:
- **Reduced code size**: Eliminate redundant nil checks in implementations
- **Better linkage**: Expose public symbols for cross-TU calls
- **Simpler Swift interop**: Swift can emit implementations without complex nil-check handling

---

## Design Overview

### Core Concept: Split Responsibilities

The optimization splits responsibilities between the **callee** (method implementation) and the **caller** (call site):

```
┌─────────────────────────────────────────────────────────────┐
│                   BEFORE (Current Design)                    │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Implementation: @"\01-[Class method]" (hidden)              │
│  ┌──────────────────────────────────────────────┐           │
│  │ if (self == nil) return 0;  ← Nil check      │           │
│  │ // actual implementation                     │           │
│  └──────────────────────────────────────────────┘           │
│                                                               │
│  Call Sites: ALL call the hidden symbol directly            │
│  - Even non-null receivers pay nil-check cost                │
│                                                               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   AFTER (New Design)                         │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  True Implementation: @"-[Class method]" (public)            │
│  ┌──────────────────────────────────────────────┐           │
│  │ // actual implementation (NO nil check)      │           │
│  └──────────────────────────────────────────────┘           │
│                                                               │
│  Thunk: @"-[Class method]_thunk" (linkonce_odr)             │
│  ┌──────────────────────────────────────────────┐           │
│  │ if (self == nil) return 0;                   │           │
│  │ musttail call @"-[Class method]"(self, ...); │           │
│  └──────────────────────────────────────────────┘           │
│                                                               │
│  Call Sites:                                                 │
│  - Non-null receivers → direct call to implementation       │
│  - Nullable receivers → call thunk                          │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Elements

#### 1. Compiler Flag
- Feature gated by: **`-fobjc-expose-direct-methods`**
- Only applies to NeXT runtime family
- Backward compatible: without flag, old behavior is preserved

#### 2. Instance Methods

**True Implementation (Callee):**
- **Symbol**: Public, no `\01` prefix (e.g., `@"-[MyClass myMethod]"`)
- **Linkage**: `external` (visible across TUs within the same linkage unit)
- **Visibility**: `hidden` (NOT exported from dylib - preserves ABI encapsulation)
- **Logic**: Contains ONLY the method implementation, NO nil check

**Rationale for hidden visibility:**
- `objc_direct` is often used to keep methods internal to avoid ABI pollution
- `ExternalLinkage` allows cross-TU calls within the same build product
- `HiddenVisibility` prevents symbols from being exported in the dylib export trie
- This preserves the original intent of `objc_direct` while enabling cross-TU usage

**Call Site (Caller):**
- **Case 1 - Non-null receiver**: Direct call to public symbol
  - Examples: `self`, `_Nonnull` annotated, class objects
- **Case 2 - Nullable receiver**: Call to caller-side thunk

**Thunk (Generated by Caller):**
- **Symbol**: Implementation symbol + `_thunk` suffix
- **Linkage**: `linkonce_odr` (linker deduplicates identical thunks)
- **Logic**:
  1. Check `if (self == nil)` → return zero-initialized value
  2. Otherwise → `musttail call` to true implementation
- **Critical**: `musttail` is required for ARC correctness (makes thunk "invisible" to ARC)

#### 3. Class Methods

**DESIGN (Full Thunk-Based Approach)**: Class methods follow the same pattern as instance methods - the true implementation contains NO nil check and NO class realization. This is the chosen design for consistency and maximum optimization.

**True Implementation (Callee):**
- **Symbol**: Public, no `\01` prefix (e.g., `@"+[MyClass myMethod]"`)
- **Linkage**: `external` (visible across TUs)
- **Visibility**: `hidden` (NOT exported from dylib)
- **Logic**: Contains ONLY the method implementation, **NO nil check**, **NO class realization**

**Call Site (Caller):**
- **Case 1 - Class is realized and non-null**: Direct call to public symbol
  - Examples: After instance method call on same class dominates the call site
  - After explicit class realization in same control flow
- **Case 2 - Class may be unrealized or null**: Call to caller-side thunk

**Thunk (Generated by Caller):**
- **Symbol**: Implementation symbol + `_thunk` suffix
- **Linkage**: `linkonce_odr`
- **Logic** (order is critical):
  1. **First**: Perform class realization: `(void)[self self];`
  2. **Second**: Check `if (self == nil)` → return zero-initialized value (only for weak-linked classes)
  3. **Third**: `musttail call` to true implementation

**Rationale for removing class realization from implementation:**
- **Consistency**: Same pattern as instance methods (clean separation of concerns)
- **Optimization**: Caller can optimize away class realization when provably unnecessary
- **Simplicity**: No special-casing for class vs instance methods in implementation
- **Thunk responsibility**: Thunk handles both class realization AND nil-check concerns

**Static Analysis for Class Methods:**
The caller needs to determine if:
1. **Is the class already realized?**
   - Has an instance method on the same class been called in a dominating path?
   - **Important**: `[Parent foo]` does NOT realize `Child` (inheritance care needed)
   - **Conservative**: Assume unrealized unless proven otherwise

2. **Can the class be nil?**
   - Is the class weak-linked? (`isWeakLinkedClass(OID)`)
   - Only weak-linked classes can be nil at runtime
   - Non-weak-linked classes are non-null after initialization

**Dispatch Decision:**
- If class is **both** realized AND non-null → direct call to implementation
- Otherwise → call thunk (which does realization + optional nil check)

**Note**: Initial implementation can conservatively always use thunks for class methods, then optimize later with better static analysis.

**Alternative Simpler Approach (Mentioned in Design Document):**
An alternative, simpler design would be to keep class realization IN the implementation with conditional nil checks. This solves the linkage problem without the complexity of thunks for class methods, at the cost of not optimizing away class realization. However, **we have chosen the full thunk-based approach** for consistency and maximum optimization potential.

#### 4. Special Case: Variadic Methods

**Problem**: Variadic methods cannot use thunks because:
- Thunk design requires `musttail` call (for ARC)
- `musttail` forbids stack management (incompatible with `va_start`/`va_end`)

**Solution**: Variadic methods get exposed symbols WITHOUT nil checks in implementation. The caller emits an inline nil check:
- **Symbol**: Public, no `\01` prefix (e.g., `@"-[MyClass varMethod:]"`)
- **Linkage**: `external` (visible across TUs)
- **Visibility**: `hidden` (NOT exported from dylib)
- **Nil checks**: **NOT in implementation** (moved to caller)
- **Caller behavior**: Emits inline nil check, then calls exposed implementation

**Rationale**: Variadic methods benefit from the same optimization (nil check removal from implementation), but since thunks can't be used due to `musttail` restrictions, the caller must emit the nil check inline before the call. This still achieves the goal of allowing non-null call sites to skip the nil check overhead.

#### 5. Nullability Analysis

To determine whether to call implementation directly or via thunk, we need static analysis of receivers:

**Provably Non-null Cases:**
1. `_Nonnull` attribute on receiver type
2. `self` parameter in instance methods
3. Class objects (type is `Class` or `id<Protocol> class`)
4. Results of `alloc`, `new` (future enhancement)
5. ObjC literals: `@"string"`, `@42`, etc. (future enhancement)

**Conservative Approach**: Default to using thunk unless definitively non-null.

---

## Implementation Phases

### Status Key
- ✅ **COMPLETED**: Implemented and tested
- 🚧 **IN PROGRESS**: Currently being worked on
- ⏸️ **PENDING**: Not yet started, waiting on dependencies
- ❌ **BLOCKED**: Cannot proceed due to issues

---

### Phase 0: Infrastructure and Compiler Flag ✅ **COMPLETED**

**Objective**: Add compiler flag and CodeGen option infrastructure.

#### Files Modified:
- `/home/peterrong/llvm-project/clang/include/clang/Basic/CodeGenOptions.def`
- `/home/peterrong/llvm-project/clang/include/clang/Driver/Options.td`

#### Changes:

1. **Add CodeGen option** (`CodeGenOptions.def`):
```cpp
CODEGENOPT(ObjCExposeDirectMethods, 1, 0, Benign)
///< Expose objc_direct method symbols publicly and optimize nil checks.
```

2. **Add compiler flag** (`Options.td`):
```cpp
defm objc_expose_direct_methods : BoolFOption<"objc-expose-direct-methods",
  CodeGenOpts<"ObjCExposeDirectMethods">, DefaultFalse,
  PosFlag<SetTrue, [], [ClangOption, CC1Option],
          "Expose direct method symbols and move nil checks to caller-side thunks">,
  NegFlag<SetFalse>>;
```

**Note**: Using the flag name `-fobjc-expose-direct-methods` with internal CodeGenOption `ObjCExposeDirectMethods`.

#### Tests Created:
- `clang/test/CodeGenObjC/expose-direct-method-flag.m` (flag recognition test - verifies flag is recognized by compiler)

**Note**: Multiple redundant test files were consolidated in Phase 1 to reduce duplication:
- ~~`expose-direct-method-stub-dispatch.m`~~ (deleted - functionality merged into main test)
- ~~`expose-direct-method-thunks.m`~~ (deleted - functionality merged into main test)
- `expose-direct-method.m` (consolidated test covering all basic functionality, stub dispatch, and thunk generation)

#### Validation:
```bash
# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang
```

---

### Phase 1: Modify Method Implementation Generation ✅ **COMPLETED**

**Objective**: Change how direct method implementations are emitted when optimization is enabled.

#### Key Design Decision: Function Separation

To improve code organization and facilitate thunk generation in Phase 3, the precondition check logic has been refactored into a separate function:

- **`GenerateDirectMethodsPreconditionCheck()`**: Handles `[self self]` for class methods and nil checks
- **`GenerateDirectMethodPrologue()`**: Handles actual prologue work (like `_cmd` synthesis)

**Design Pattern:**
- **With flag enabled (`shouldExposeSymbol == true`)**:
  - True implementation calls only `GenerateDirectMethodPrologue()` (no preconditions)
  - Thunk will call `GenerateDirectMethodsPreconditionCheck()` (in Phase 3)
- **Without flag (`shouldExposeSymbol == false`)**:
  - `GenerateDirectMethodPrologue()` dispatches to `GenerateDirectMethodsPreconditionCheck()`
  - Then performs its own prologue work
  - This maintains backward compatibility

**Rationale**: This separation of concerns makes the code cleaner, more maintainable, and enables thunks to easily reuse the precondition check logic without code duplication.

#### Files Modified:
- `/home/peterrong/llvm-project/clang/include/clang/AST/DeclObjC.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCRuntime.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCRuntime.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjC.cpp`

#### Changes:

**1. Add eligibility check** (`DeclObjC.h`):
```cpp
/// Check if this method can have nil-check thunk optimization.
bool canHaveNilCheckThunk() const {
  // Variadic functions cannot use thunks (musttail incompatible with va_arg)
  // musttail is primarily supported on arm64 (Apple platforms)
  return isDirectMethod() && !isVariadic();
}
```

**Note**: Platform-specific musttail support should also be checked in CodeGenModule, though this is primarily relevant for arm64/Apple platforms where objc_direct is most commonly used.

**2. Add optimization checks** (`CodeGenModule.h`):
```cpp
/// Check if a direct method should have its symbol exposed (no \01 prefix).
/// This applies to ALL direct methods (including variadic).
/// Returns false if OMD is null or not a direct method.
bool shouldExposeSymbol(const ObjCMethodDecl *OMD) const {
  return OMD &&
         OMD->isDirectMethod() &&
         getLangOpts().ObjCRuntime.isNeXTFamily() &&
         getCodeGenOpts().ObjCExposeDirectMethods;
}

/// Check if a direct method should use nil-check thunks at call sites.
/// This applies only to non-variadic direct methods.
/// Variadic methods cannot use thunks (musttail incompatible with va_arg).
/// Returns false if OMD is null or not eligible for thunks.
bool shouldHaveNilCheckThunk(const ObjCMethodDecl *OMD) const {
  return OMD &&
         shouldExposeSymbol(OMD) &&
         OMD->canHaveNilCheckThunk();
}

/// Check if a direct method should have inline nil checks at call sites.
/// This applies to direct methods that cannot use thunks (e.g., variadic methods).
/// These methods get exposed symbols but need inline nil checks instead of thunks.
/// Returns false if OMD is null or not eligible for inline nil checks.
bool shouldHaveNilCheckInline(const ObjCMethodDecl *OMD) const {
  return OMD &&
         shouldExposeSymbol(OMD) &&
         !OMD->canHaveNilCheckThunk();
}
```

**Note**: By including null checks and `isDirectMethod()` checks in these helper methods, we eliminate redundant checks at call sites. Call sites can simply use `if (CGM.shouldExposeSymbol(Method))` instead of `if (Method && Method->isDirectMethod() && CGM.shouldExposeSymbol(Method))`.

**3. Refactor symbol name generation** (`CGObjCRuntime.h/cpp`):
```cpp
// Merge overloads with default parameter
std::string getSymbolNameForMethod(const ObjCMethodDecl *method,
                                   bool includeCategoryName = true,
                                   bool includePrefixByte = true);
```
- Allows removing `\01` prefix when optimization is enabled

**4. Modify `GenerateDirectMethod()`** (`CGObjCMac.cpp`):
```cpp
bool ExposeSymbol = CGM.shouldExposeSymbol(OMD);

// Generate symbol without \01 prefix when optimization enabled
auto Name = getSymbolNameForMethod(OMD, /*includeCategoryName*/ false,
                                   /*includePrefixByte*/ !ExposeSymbol);

// ALWAYS use ExternalLinkage for true implementation
Fn = llvm::Function::Create(MethodTy, llvm::GlobalValue::ExternalLinkage,
                            Name, &CGM.getModule());
```

**5. Refactor `GenerateDirectMethodPrologue()` and Extract `GenerateDirectMethodsPreconditionCheck()`** (`CGObjCMac.cpp`):

To improve code organization and facilitate thunk generation in Phase 3, the precondition check logic has been separated into a new function:

**New Function: `GenerateDirectMethodsPreconditionCheck()`**
```cpp
void CGObjCCommonMac::GenerateDirectMethodsPreconditionCheck(
    CodeGenFunction &CGF, llvm::Function *Fn, const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD) {

  // For class methods: perform [self self] for class realization
  if (OMD->isClassMethod()) {
    const ObjCInterfaceDecl *OID = cast<ObjCInterfaceDecl>(CD);
    // ... perform [self self] for class realization ...
    ReceiverCanBeNull = isWeakLinkedClass(OID);
  }

  // Generate nil check for potentially nullable receivers
  if (ReceiverCanBeNull) {
    // ... generate nil check code ...
  }
}
```

**Refactored: `GenerateDirectMethodPrologue()`**
```cpp
void CGObjCCommonMac::GenerateDirectMethodPrologue(
    CodeGenFunction &CGF, llvm::Function *Fn, const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD) {

  bool shouldExposeSymbol = CGM.shouldExposeSymbol(OMD);

  // Generate precondition checks (class realization + nil check) if needed
  // Without flag: precondition checks are in the implementation
  // With flag: precondition checks will be in the thunk (not here)
  if (!shouldExposeSymbol) {
    GenerateDirectMethodsPreconditionCheck(CGF, Fn, OMD, CD);
  }

  // Only synthesize _cmd if it's referenced
  // This is the actual "prologue" work that always happens
  if (OMD->getCmdDecl()->isUsed()) {
    // ... synthesize _cmd ...
  }
}
```

**Design Pattern:**
- **With flag enabled (`shouldExposeSymbol == true`)**:
  - True implementation calls only `GenerateDirectMethodPrologue()` (no preconditions)
  - Thunk will call `GenerateDirectMethodsPreconditionCheck()` (in Phase 3)
- **Without flag (`shouldExposeSymbol == false`)**:
  - `GenerateDirectMethodPrologue()` dispatches to `GenerateDirectMethodsPreconditionCheck()`
  - Then performs its own prologue work
  - This maintains backward compatibility

**IMPORTANT**: With this change, when optimization is enabled:
- **Instance methods**: NO nil check in implementation
- **Class methods**: NO class realization AND NO nil check in implementation
- Both will be handled by thunks at call sites (to be implemented in Phase 3)

This follows the **full thunk-based approach** as described in the design section above, ensuring consistency between instance and class methods and enabling maximum optimization.

**Rationale for Separation**: Extracting precondition checks into a separate function makes the code cleaner, more maintainable, and enables thunks to easily reuse the precondition check logic without code duplication.

**6. Update visibility** (`CGObjC.cpp`):
```cpp
if (OMD->isDirectMethod()) {
  // IMPORTANT: Keep hidden visibility even when optimization enabled
  // - ExternalLinkage allows cross-TU calls within the same build product
  // - HiddenVisibility prevents dylib export (preserves ABI encapsulation)
  // - Only use DefaultVisibility if explicitly marked visibility("default")
  Fn->setVisibility(llvm::Function::HiddenVisibility);
  // ... rest of code
}
```

#### Key Design Decisions:
- **External linkage + Hidden visibility**: Cross-TU calls without dylib export pollution
- **Remove class realization from class methods**: When optimization enabled, class method implementations have NO `[self self]` call - it will be done in the thunk
- **Variadic exclusion**: Explicitly check `!isVariadic()`
- **musttail platform guard**: Check platform support (primarily arm64/Apple platforms)

#### Tests Created:
- `clang/test/CodeGenObjC/expose-direct-method-disabled.m` (backward compatibility)
- `clang/test/CodeGenObjC/expose-direct-method-varargs.m` (variadic exclusion)
- `clang/test/CodeGenObjC/expose-direct-method.m` (main test, currently XFAIL'd)

#### Validation:
```bash
# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang
```

---

### Phase 2: Stub Dispatch Helper Functions ✅ **COMPLETED**

**Objective**: Create stub implementations of dispatch helper functions to enable end-to-end feature completion. These will be optimized in Phase 7.

**Rationale**:
- These functions are **optimizations, not required for correctness**
- By conservatively returning `false`, we always use thunks (safest approach)
- This allows us to complete Phases 3-6 and get the feature working end-to-end
- Actual optimization logic can be implemented and tested separately in Phase 7

#### Files Modified:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.h`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-stub-dispatch.m`

#### Changes:

**Design Decision: Reuse Existing `canMessageReceiverBeNull` Infrastructure**

Instead of creating new functions, we'll enhance the existing `canMessageReceiverBeNull` in `CGObjCRuntime`:
- The base class already has good nullability analysis logic
- `CGObjCCommonMac` can override to add NeXT-runtime-specific heuristics
- This follows OOP principles and avoids code duplication

**1. Make `canMessageReceiverBeNull` virtual** (`CGObjCRuntime.h`):

```cpp
/// Check if the receiver of an ObjC message send can be null.
/// Returns true if the receiver may be null, false if provably non-null.
///
/// This can be overridden by subclasses to add runtime-specific heuristics.
/// Base implementation checks:
/// - Super dispatch (always non-null)
/// - Self in const-qualified methods (ARC)
/// - Weak-linked classes
///
/// Future enhancements in CGObjCCommonMac override:
/// - _Nonnull attributes
/// - Results of alloc, new, ObjC literals
virtual bool canMessageReceiverBeNull(CodeGenFunction &CGF,
                              const ObjCMethodDecl *method, bool isSuper,
                              const ObjCInterfaceDecl *classReceiver,
                              llvm::Value *receiver);
```

**2. Add class realization check** (`CGObjCRuntime.h`):

```cpp
/// Check if a class object can be unrealized (not yet initialized).
/// Returns true if the class may be unrealized, false if provably realized.
///
/// STUB IMPLEMENTATION: Base class always returns true (conservative).
/// Subclasses can override to add runtime-specific dominating-call analysis.
///
/// Future: Returns false if:
/// - An instance method on the same class was called in a dominating path
/// - The class was explicitly realized earlier in control flow
/// - Note: [Parent foo] does NOT realize Child (inheritance care needed)
virtual bool canClassObjectBeUnrealized(const ObjCInterfaceDecl *ClassDecl,
                                        CodeGenFunction &CGF) const;
```

**3. Add stub implementation in base class** (`CGObjCRuntime.cpp`):

```cpp
bool CGObjCRuntime::canClassObjectBeUnrealized(
    const ObjCInterfaceDecl *ClassDecl, CodeGenFunction &CGF) const {
  // STUB: Base implementation always returns true (conservative).
  // Subclasses can override to add runtime-specific analysis.
  // This means class method thunks will always perform class realization,
  // which is safe (realizing an already-realized class is a no-op).
  return true;
}
```

**4. Usage in CodeGen** (`CGObjC.cpp` and other call sites):

Call sites will directly use the runtime methods:

```cpp
// Check if receiver can be null (returns true if nullable)
bool receiverCanBeNull = CGM.getObjCRuntime().canMessageReceiverBeNull(
    CGF, Method, IsSuper, ClassReceiver, Receiver);

if (!receiverCanBeNull) {
  // Receiver is provably non-null: call implementation directly
  // ...
} else {
  // Receiver may be null: use thunk
  // ...
}

// Check if class can be unrealized (returns true if may be unrealized)
bool classCanBeUnrealized = CGM.getObjCRuntime().canClassObjectBeUnrealized(
    ClassDecl, CGF);

if (!classCanBeUnrealized) {
  // Class is provably realized: skip realization in thunk
  // ...
} else {
  // Class may be unrealized: perform realization
  // ...
}
```

No wrapper functions needed in `CodeGenModule` - just directly call the runtime.

#### Why This Approach Works:

**For `canMessageReceiverBeNull`:**
- Returning `true` → all instance method calls use thunks
- Thunks perform nil check (safe, just not optimized)
- No correctness issues, just missed optimization opportunities

**For `canClassObjectBeUnrealized`:**
- Returning `true` → all class method thunks perform `[self self]` realization
- Safe because realizing an already-realized class is a no-op
- No correctness issues, just potentially redundant class realization

#### Test Created:
- No new tests needed (stubs don't change behavior)
- Tests in Phases 3-6 will work with conservative approach

#### Validation:
```bash
# Should compile successfully
ninja -C build-debug clang
```

---

### Phase 3: Implement Thunk Generation ✅ **COMPLETED**

**Objective**: Generate nil-check thunks for nullable receivers, both for methods defined in the current TU and for cross-TU calls.

#### Summary of Accomplishments:

Phase 3 successfully implemented the complete thunk generation infrastructure, enabling caller-side nil-check thunks for direct methods. This phase introduced several architectural improvements:

**Key Achievements:**
1. **DirectMethodInfo Structure**: Created a unified cache structure storing both Implementation and Thunk together, enabling atomic updates when type covariance causes implementation replacement
2. **Thunk Generation**: Implemented `GenerateObjCDirectThunk()` which creates linkonce_odr thunks with proper nil-checking logic and musttail calls
3. **Dispatch Logic**: Added `GetDirectMethodCallee()` to centralize decision-making for whether to call implementation directly or via thunk
4. **Lifecycle Management**: Introduced `StartObjCDirectThunk()`/`FinishObjCDirectThunk()` borrowed from C++ vtable thunks for proper function generation
5. **Integration**: Partially integrated thunk dispatch into `EmitMessageSend()` in `CGObjCMac.cpp`
6. **Comprehensive Testing**: Added extensive tests covering:
   - Basic instance and class methods
   - Property accessors (direct properties)
   - Methods in extensions and categories
   - Complex return types (structs, aggregates, sret)
   - Cross-TU calls (methods declared but not defined in current TU)
   - Type covariance scenarios

**Technical Details:**
- Thunks use `linkonce_odr` linkage for linker deduplication across TUs
- `musttail` calls ensure ARC transparency
- Thunks reuse `GenerateDirectMethodsPreconditionCheck()` from Phase 1 for class realization and nil checks
- Proper attribute copying ensures calling convention and parameter attributes match between thunk and implementation

**What Works:**
- Non-variadic direct methods generate both implementation and thunk
- Call sites can choose between implementation and thunk based on nullability flags
- Cross-TU calls generate thunks on-demand
- Type covariance correctly regenerates thunks when implementation types change

#### Files Modified:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp`
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenFunction.h`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/direct-method-ret-mismatch.m`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-stub-dispatch.m` (deleted - merged into main test)
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-varargs.m`
- `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method.m`

#### Design Overview:

**Key Insight**: `GenerateDirectMethod()` has two different usage patterns that need different return values:
1. **Body Generation** (`GenerateMethod`): Needs TRUE IMPLEMENTATION (where method body is emitted)
2. **Call Sites** (`EmitMessageSend`): Needs IMPLEMENTATION or THUNK (based on nullability)

**Solution**: Change `GenerateDirectMethod()` to return `DirectMethodInfo&` (containing both), add new `GetDirectMethodCallee()` for call sites.

#### Changes:

**1. Update DirectMethodDefinitions cache structure** (`CGObjCMac.cpp`):

```cpp
// BEFORE (old structure):
llvm::DenseMap<const ObjCMethodDecl *, llvm::Function *> DirectMethodDefinitions;

// AFTER (new structure):
/// Information about a direct method definition
struct DirectMethodInfo {
  llvm::Function *Implementation;  // The true implementation (where body is emitted)
  llvm::Function *Thunk;            // The nil-check thunk (nullptr if not generated)

  DirectMethodInfo(llvm::Function *Impl)
    : Implementation(Impl), Thunk(nullptr) {}
};

llvm::DenseMap<const ObjCMethodDecl *, DirectMethodInfo> DirectMethodDefinitions;
```

**Rationale**: When Objective-C type covariance causes implementation replacement, we must also replace the thunk to maintain musttail compatibility. Storing both together enables atomic updates.

**2. Update GenerateMethod() to extract Implementation** (`CGObjCMac.cpp`):

```cpp
llvm::Function *CGObjCCommonMac::GenerateMethod(const ObjCMethodDecl *OMD,
                                                const ObjCContainerDecl *CD) {
  llvm::Function *Method;

  if (OMD->isDirectMethod()) {
    // Returns DirectMethodInfo& containing both Implementation and Thunk
    DirectMethodInfo& Info = GenerateDirectMethod(OMD, CD);
    Method = Info.Implementation;  // Extract implementation for body generation
  } else {
    auto Name = getSymbolNameForMethod(OMD);

    CodeGenTypes &Types = CGM.getTypes();
    llvm::FunctionType *MethodTy =
        Types.GetFunctionType(Types.arrangeObjCMethodDeclaration(OMD));
    Method = llvm::Function::Create(
        MethodTy, llvm::GlobalValue::InternalLinkage, Name, &CGM.getModule());
  }

  MethodDefinitions.insert(std::make_pair(OMD, Method));

  return Method;
}
```

**3. Modify GenerateDirectMethod() to return DirectMethodInfo&** (`CGObjCMac.cpp`):

**Key Change**: Returns reference to `DirectMethodInfo` (both Implementation and Thunk), not just the implementation function.

```cpp
DirectMethodInfo&
CGObjCCommonMac::GenerateDirectMethod(const ObjCMethodDecl *OMD,
                                      const ObjCContainerDecl *CD) {
  auto *COMD = OMD->getCanonicalDecl();
  auto I = DirectMethodDefinitions.find(COMD);
  llvm::Function *OldFn = nullptr, *Fn = nullptr;

  // ... existing code to check cache and create implementation function ...

  if (I != DirectMethodDefinitions.end()) {
    // Method already defined, get existing implementation
    OldFn = I->second.Implementation;
    // ... handle type mismatch if needed ...
  }

  // Create the implementation function
  // ... existing code to create Fn ...

  // Store in cache
  if (I == DirectMethodDefinitions.end()) {
    // First time seeing this method
    DirectMethodInfo Info(Fn);
    DirectMethodDefinitions.insert(std::make_pair(COMD, Info));
    I = DirectMethodDefinitions.find(COMD);
  } else {
    // Update existing entry
    I->second.Implementation = Fn;
    llvm::Function *OldThunk = I->second.Thunk;

    // CRITICAL: If implementation was replaced, and old thunk exists, invalidate the old thunk
    if (OldFn && OldThunk) {

      // Type mismatch occurred - regenerate thunk with correct type
      llvm::Function *NewThunk = GenerateThunkForDirectMethod(OMD, CD, Fn);

      // Replace all uses before erasing
      NewThunk->takeName(OldThunk);
      OldThunk->replaceAllUsesWith(NewThunk);
      OldThunk->eraseFromParent();

      I->second.Thunk = NewThunk;
    }
  }

  // Generate thunk if optimization is enabled (only if not already created above)
  if (CGM.shouldHaveNilCheckThunk(OMD) && !I->second.Thunk) {
    llvm::Function *Thunk = GenerateThunkForDirectMethod(OMD, CD, Fn);
    I->second.Thunk = Thunk;
  }

  // Return reference to DirectMethodInfo (contains both Implementation and Thunk)
  return I->second;
}
```

**4. Add new helper: GenerateObjCDirectThunk()** (`CGObjCMac.cpp`):

```cpp
llvm::Function *
CGObjCCommonMac::GenerateThunkForDirectMethod(
    const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD,
    llvm::Function *Implementation) {

  assert(CGM.shouldHaveNilCheckThunk(OMD) && "Should only generate thunk when optimization enabled");
  assert(Implementation && "Implementation must exist");

  // Get function type (same as implementation)
  llvm::FunctionType *ThunkTy = Implementation->getFunctionType();

  // Generate thunk name: implementation symbol + "_thunk"
  std::string ThunkName = Implementation->getName().str() + "_thunk";

  // Create thunk with linkonce_odr linkage (allows deduplication)
  llvm::Function *Thunk = llvm::Function::Create(
      ThunkTy,
      llvm::GlobalValue::LinkOnceODRLinkage,
      ThunkName,
      &CGM.getModule());

  // Set attributes
  Thunk->setVisibility(llvm::GlobalValue::HiddenVisibility);
  Thunk->setUnnamedAddr(llvm::GlobalValue::UnnamedAddr::Global);

  // CRITICAL: Copy function-level attributes from implementation
  llvm::AttributeList ImplAttrs = Implementation->getAttributes();
  Thunk->setAttributes(ImplAttrs);

  // Build argument list for StartFunction
  // CRITICAL: For musttail thunks, we MUST NOT pass regular method parameters
  // to StartFunction because that causes them to be stored in local variables
  // with storeStrong, which adds ARC retains/releases. This breaks the thunk's
  // ARC transparency!
  //
  // We only pass 'self' so we can perform the nil check on it.
  // All other parameters will be forwarded directly from Thunk->args().
  FunctionArgList FunctionArgs;
  FunctionArgs.push_back(OMD->getSelfDecl());
  // DO NOT append other parameters here - they would trigger storeStrong!

  // Get CGFunctionInfo for this method
  const CGFunctionInfo &FI = CGM.getTypes().arrangeObjCMethodDeclaration(OMD);

  // Create a CodeGenFunction to generate the thunk body
  // This gives us access to helper functions like GenerateDirectMethodsPreconditionCheck
  CodeGenFunction CGF(CGM);
  CGF.CurFuncDecl = OMD;
  CGF.CurCodeDecl = OMD;

  // Start the function with CORRECT return type (not VoidTy!)
  // This sets up the function prologue, entry block, allocas, etc.
  CGF.StartFunction(GlobalDecl(OMD), OMD->getReturnType(), Thunk, FI, FunctionArgs,
                    OMD->getLocation(), OMD->getLocation());

  // REUSE Phase 1's precondition check logic!
  // This generates: [self self] for class methods + nil check
  GenerateDirectMethodsPreconditionCheck(CGF, Thunk, OMD, CD);

  // After precondition check, make musttail call to implementation
  // Get all arguments
  SmallVector<llvm::Value*, 8> Args;
  for (auto &Arg : Thunk->args())
    Args.push_back(&Arg);

  // Create musttail call
  llvm::CallInst *Call = CGF.Builder.CreateCall(Implementation, Args);
  Call->setTailCallKind(llvm::CallInst::TCK_MustTail);
  Call->setCallingConv(Implementation->getCallingConv());

  // Return the result (or void)
  if (FI.getReturnInfo().isIndirect()) {
    // SRet case: return void
    CGF.Builder.CreateRetVoid();
  } else {
    llvm::Type *RetTy = ThunkTy->getReturnType();
    if (RetTy->isVoidTy())
      CGF.Builder.CreateRetVoid();
    else
      CGF.Builder.CreateRet(Call);
  }

  // Finish the function - emits epilogue, cleanup, etc.
  // This is REQUIRED to properly finalize the function
  CGF.FinishFunction();

  // Return the thunk (caller will cache it)
  return Thunk;
}
```

**5. Add new dispatch function: GetDirectMethodCallee()** (`CGObjCMac.cpp`):

This function centralizes the decision logic for choosing between implementation and thunk at call sites.

```cpp
llvm::Function *
CGObjCCommonMac::GetDirectMethodCallee(const ObjCMethodDecl *OMD,
                                       const ObjCContainerDecl *CD,
                                       bool ReceiverCanBeNull,
                                       bool ClassObjectCanBeUnrealized) {
  DirectMethodInfo& Info = GenerateDirectMethod(OMD, CD);

  // If optimization not enabled, always use implementation (which includes the nil check)
  if (!CGM.shouldExposeSymbol(OMD)) {
    return Info.Implementation;
  }

  // Variadic methods don't have thunk, the caller needs to inline the nil check
  if (CGM.shouldHaveNilCheckInline(OMD)) {
    return Info.Implementation;
  }

  assert(CGM.shouldHaveNilCheckThunk(OMD));

  if (OMD->isInstanceMethod()) {
    // If we can prove instance method's receiver is not null, return the true implementation
    return ReceiverCanBeNull ? Info.Thunk : Info.Implementation;
  } else if (OMD->isClassMethod()) {
    // For class methods, it needs to be non-null and realized before we dispatch to true implementation
    return (ReceiverCanBeNull || ClassObjectCanBeUnrealized)
               ? Info.Thunk
               : Info.Implementation;
  } else {
    assert(false && "OMD should either be a class method or instance method");
  }
}
```

**Key Simplifications from Original Plan:**
- ✅ **Single source of truth**: All dispatch logic in one place
- ✅ **Simpler interface**: Callers just pass nullability flags, not complex expressions
- ✅ **Clearer logic**: Easy to understand the decision tree
- ✅ **Better separation**: Nullability analysis is done by the caller, dispatch is done here

**6. Add thunk lifecycle helpers** (`CodeGenFunction.h` and `CGObjCMac.cpp`):

Borrowed from C++ vtable thunks in `CGVTables.cpp`, these helpers properly manage thunk function generation:

```cpp
/// Start an Objective-C direct method thunk.
void CodeGenFunction::StartObjCDirectThunk(const ObjCMethodDecl *OMD,
                                           llvm::Function *Fn,
                                           const CGFunctionInfo &FnInfo,
                                           const FunctionArgList &Args) {
  // Similar to StartThunk() for C++ virtual methods
  // Sets up function state without requiring an AST body
  StartFunction(GlobalDecl(), OMD->getReturnType(), Fn, FnInfo, Args,
                OMD->getLocation(), OMD->getLocation());

  // Manually set the decl so other utilities can access the AST
  CurCodeDecl = OMD;
  CurFuncDecl = OMD;
}

/// Finish an Objective-C direct method thunk.
void CodeGenFunction::FinishObjCDirectThunk() {
  // Create dummy unreachable block (removed by optimizer)
  EmitBlock(createBasicBlock());

  // Disable final ARC autorelease (thunk uses musttail)
  AutoreleaseResult = false;

  // Restore invariants
  CurCodeDecl = nullptr;
  CurFuncDecl = nullptr;

  FinishFunction();
}
```

**Architectural Improvements over Original Plan:**
- ✅ **`DirectMethodInfo` struct**: Stores Implementation + Thunk together for atomic updates
- ✅ **Better type covariance handling**: When implementation is replaced, thunk is also regenerated
- ✅ **Cleaner separation**: `GenerateDirectMethod()` for generation, `GetDirectMethodCallee()` for dispatch
- ✅ **Reuses Phase 1 code**: Thunks call `GenerateDirectMethodsPreconditionCheck()`
- ✅ **Proper lifecycle management**: `StartObjCDirectThunk()` / `FinishObjCDirectThunk()` borrowed from C++ thunks

#### Critical Implementation Details:

**1. LinkOnceODR Linkage**
- Multiple translation units may generate identical thunks
- Linker will deduplicate them (keeping one definition)
- `UnnamedAddr::Global` allows more aggressive optimization

**2. MustTail Call**
- **Critical for ARC**: Makes thunk transparent to ARC optimizer
- Ensures no ARC operations between thunk and implementation
- Requirements:
  - Return type must match
  - Calling convention must match
  - All arguments must be forwarded

**3. Class Realization (Class Methods) - NEW DESIGN**

According to the updated design, class method thunks should:
1. **First**: Perform class realization via `[self self]`
2. **Second**: Check if self == nil (only for weak-linked classes)
3. **Third**: musttail call to implementation

**Order is important**: Class realization happens BEFORE nil check.

**IMPORTANT NOTE**: The current implementation (Phases 0-1) follows the **simpler alternative** where class methods:
- Keep class realization IN the implementation
- Skip nil checks when optimization enabled (unless weak-linked)
- Do NOT use thunks

If/when implementing full thunk support for class methods (future work), follow this pattern:
```cpp
// Thunk for class method:
// Step 1: Realize the class
(void)[self self];

// Step 2: Check if class is nil (only for weak-linked classes)
if (self == nil && isWeakLinkedClass(OID))
  return zero_value;

// Step 3: musttail call to true implementation (which has NO realization, NO nil check)
musttail call @"+[Class method]"(self, ...);
```

**4. Return Value Handling**
- Void methods: `ret void`
- Primitive types: return zero (`0`, `0.0`, etc.)
- Pointer types: return null (`nullptr`)
- Struct types: return zero-initialized struct

#### Edge Cases to Handle:

1. **Methods with struct return types**
   - May use sret (struct return) parameter
   - Must correctly forward sret parameter in musttail call

2. **Methods with complex attributes**
   - Copy relevant attributes from implementation to thunk
   - Examples: `nounwind`, `readonly`, `willreturn`

3. **Variadic methods**
   - Should NOT reach thunk generation (filtered in Phase 1)
   - Add assertion: `assert(!OMD->isVariadic())`

#### Testing:
```cpp
// Test struct return
struct Point { int x, y; };
- (struct Point)getPoint __attribute__((objc_direct));

// Test void return
- (void)doSomething __attribute__((objc_direct));

// Test pointer return
- (id)getObject __attribute__((objc_direct));
```

---

### Phase 4: Integrate Call Site Logic and Variadic Methods ✅ **COMPLETED**

**Objective**: Update call sites to use `GetDirectMethodCallee()` which decides whether to call implementation or thunk based on nullability. Additionally, implement inline nil checks for variadic methods which cannot use thunks.

#### Summary of Accomplishments:

Phase 4 successfully completed the integration of variadic method handling with inline nil checks, addressing all the requirements:

**Key Achievements:**
1. **Variadic Method Inline Nil Checks**: Implemented inline nil check emission for variadic direct methods using the existing `NullReturnState` infrastructure
2. **Class Realization for Variadic Class Methods**: Added class realization via `GenerateClassRealization()` helper for variadic class methods before nil checks
3. **Code Refactoring**: Extracted `GenerateClassRealization()` helper function to eliminate code duplication between `EmitMessageSend` and `GenerateDirectMethodsPreconditionCheck`
4. **Fixed Edge Case**: Ensured nil checks are emitted for variadic methods even when return value is unused (e.g., void methods)
5. **Clean Code Flow**: Separated class realization (happens early) from nil check decision (happens after `Return.isUnused()` logic)

#### What Works:
- ✅ Variadic instance methods with nullable receivers get inline nil checks
- ✅ Variadic class methods perform class realization before nil checks
- ✅ Non-variadic direct methods use thunk dispatch via `GetDirectMethodCallee()`
- ✅ Variadic methods with void return correctly emit nil checks
- ✅ Variadic methods with non-null receivers (self) skip nil checks
- ✅ Class realization code is shared via helper function (no duplication)

#### Files Modified/To Modify:
- ✅ `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp` (GetDirectMethodCallee implemented, EmitMessageSend partially updated)
- ⏸️ `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjC.cpp` (may need updates for call site emission)
- ⏸️ `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-varargs.m` (expand tests for variadic inline nil checks)

#### Changes:

**Note**: The implemented version of `GetDirectMethodCallee()` has a simpler signature than originally planned:

```cpp
// Implemented signature (simpler):
llvm::Function *GetDirectMethodCallee(
    const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD,
    bool ReceiverCanBeNull,
    bool ClassObjectCanBeUnrealized);

// vs. Original plan (more complex):
llvm::Function *GetDirectMethodCallee(
    const ObjCMethodDecl *OMD,
    const ObjCContainerDecl *CD,
    llvm::Value *Receiver,
    bool IsSuper,
    const ObjCInterfaceDecl *ClassReceiver,
    CodeGenFunction &CGF);
```

**Why the change is better:**
- Simpler interface: caller performs nullability analysis, GetDirectMethodCallee just dispatches
- Better separation of concerns: analysis vs. dispatch
- Easier to test and reason about

**2. Implementation in EmitMessageSend** (`CGObjCMac.cpp`):

The implementation integrates directly into `EmitMessageSend()` in `CGObjCMac.cpp`:

```cpp
// In EmitMessageSend (around line 2100)

if (Method && Method->isDirectMethod()) {
    bool ClassObjectCanBeUnrealized =
        Method->isClassMethod() &&
        canClassObjectBeUnrealized(ClassReceiver, CGF);

    // Use GetDirectMethodCallee to decide whether to use implementation or thunk
    // This handles:
    // - Cache lookup in DirectMethodDefinitions
    // - Creating function declarations for cross-TU calls
    // - Deciding implementation vs thunk based on nullability
    Fn = GetDirectMethodCallee(Method, Method->getClassInterface(),
                               ReceiverCanBeNull, ClassObjectCanBeUnrealized);

    // Direct methods synthesize _cmd internally, don't need to pass it
    RequiresSelValue = false;

    // ... rest of call emission ...
}
```

**Why This Implementation is Clean:**
- ✅ `GetDirectMethodCallee()` handles all complexity internally:
  - Cache lookups in `DirectMethodDefinitions` map
  - Creating function declarations for cross-TU calls (methods defined elsewhere)
  - Deciding whether to return Implementation or Thunk based on nullability
- ✅ Integrates naturally into existing message send infrastructure
- ✅ Reuses existing `ReceiverCanBeNull` calculation from earlier in `EmitMessageSend`
- ✅ Works seamlessly with existing `NullReturnState` for variadic methods
- ✅ No code duplication - single source of truth in `GetDirectMethodCallee()`

**Cross-TU Handling:**
When a direct method is declared but not defined in the current translation unit, `GenerateDirectMethod()` (called by `GetDirectMethodCallee()`) automatically creates a function declaration with the correct external linkage and hidden visibility. The linker will resolve this to the actual implementation in another object file.

#### Implementation Details:

**Handle Variadic Methods (Special Case)**

Variadic methods are excluded from the thunk optimization (`!canHaveNilCheckThunk()`), but still get exposed symbols. The caller must emit an inline nil check:

**Simple Implementation - Reuse Existing Infrastructure:**

The existing `NullReturnState` infrastructure in `EmitMessageSend()` already handles inline nil checks perfectly. We just need to set `RequiresNullCheck = true` for variadic direct methods with nullable receivers.

```cpp
// In EmitMessageSend, after all the RequiresNullCheck logic:

if (CGM.shouldHaveNilCheckInline(Method)) {
  // For variadic class methods, perform class realization FIRST
  if (ClassReceiver && ClassObjectCanBeUnrealized) {
    Arg0 = GenerateClassRealization(CGF, Arg0, ClassReceiver);
    ActualArgs[0] = CallArg(RValue::get(Arg0), ActualArgs[0].Ty);
  }

  // Set RequiresNullCheck to trigger existing nil check infrastructure
  // This works even if Return.isUnused() previously reset it
  RequiresNullCheck |= ReceiverCanBeNull;
}

// Later in EmitMessageSend, the existing code handles everything:
NullReturnState nullReturn;
if (RequiresNullCheck) {
  nullReturn.init(CGF, Arg0);  // Creates nil check blocks
}
// ... emit call ...
return nullReturn.complete(...);  // Handles PHI nodes for all return types
```

**Why This Works:**

The `NullReturnState` infrastructure automatically:
- Creates basic blocks for nil and non-nil cases
- Emits the nil check: `if (receiver == nil)`
- Returns zero-initialized values for nil case
- Creates PHI nodes to merge results
- Handles all return types (void, scalar, aggregate, complex)

**No new code needed** - we just reuse the existing, well-tested infrastructure!

**Rationale**: Variadic methods get exposed symbols (no `\01` prefix) and have NO nil checks in their implementation. Since thunks can't be used (musttail restrictions with va_arg), setting `RequiresNullCheck` triggers the inline nil check. This still achieves the optimization goal: non-null call sites (like `self`) skip the nil check entirely.

#### Testing Scenarios:

**Test 1: Non-null receiver calls implementation directly**
```objc
- (int)caller {
  return [self directMethod];  // self is non-null
}
// Expected: direct call to @"-[Class directMethod]"
```

**Test 2: Nullable receiver calls thunk**
```objc
int caller(MyClass *obj) {
  return [obj directMethod];  // obj may be nil
}
// Expected: call to @"-[Class directMethod]_thunk"
```

**Test 3: _Nonnull receiver calls implementation**
```objc
int caller(MyClass *_Nonnull obj) {
  return [obj directMethod];  // obj is non-null
}
// Expected: direct call to @"-[Class directMethod]"
```

**Test 4: Class method**
```objc
int caller() {
  return [MyClass classMethod];  // class is non-null
}
// Expected (CURRENT IMPLEMENTATION - Simpler Approach):
//   direct call to @"+[Class classMethod]"
//   (implementation has [self self] but no nil check)
//
// Expected (FUTURE with full thunk approach):
//   If class is already realized: direct call to @"+[Class classMethod]"
//   If class needs realization: call to @"+[Class classMethod]_thunk"
//   (thunk does [self self], then musttail call to implementation)
//   (implementation has NO [self self] and NO nil check)
```

**IMPORTANT NOTE ON CLASS METHODS**: The current implementation (Phases 0-1) uses the simpler approach where class methods keep `[self self]` in the implementation. If/when implementing the full thunk-based approach for class methods, the caller will need to perform static analysis to determine:

1. **Is the class already realized?**
   - Has an instance method on the same class been called in a dominating path?
   - Extra care for inheritance: `[Parent foo]` does NOT realize `Child`

2. **Can the class be nil?**
   - Is the class weak-linked? (`isWeakLinkedClass(OID)`)
   - Only weak-linked classes can be nil at runtime

3. **Dispatch logic:**
   - If class is realized AND non-null → direct call to implementation
   - Otherwise → call thunk (which does realization + nil check)

The simpler approach avoids this complexity by always including `[self self]` in class method implementations.

---

### Phase 5: Corner Cases, Validation, and Darwin-Specific Testing ⏸️ **PENDING**

**Objective**: Address all corner cases, validate ARC correctness, and conduct executable tests on Darwin platforms to ensure the generated code works correctly in production.

**Important Note**: At this phase, development should ideally move to a Darwin (macOS/iOS) platform to validate that the generated machine code executes correctly. LLVM IR correctness is not sufficient - we need to verify runtime behavior on actual Apple platforms.

#### 5.1: ARC Correctness Validation

**Critical Requirement**: Thunks must be completely transparent to ARC - the thunk should not affect retain/release behavior in any way.

**Why This Matters**:
- ARC optimizer makes assumptions about object lifetimes
- Incorrect thunk implementation can cause:
  - Use-after-free bugs
  - Memory leaks
  - Double-free crashes
- `musttail` is CRITICAL - it makes the thunk "invisible" to ARC

**Validation Strategy**:

1. **Unit Tests with ARC Scenarios**:
```objc
// Test 1: Parameter passing with ARC
// The parameter should not be over-retained or under-retained
- (id)passthrough:(id)param __attribute__((objc_direct)) {
  return param;  // Should maintain correct retain count
}

void testPassthrough(MyClass *obj, id input) {
  id result = [obj passthrough:input];
  // Verify: input retain count is correct
  // Verify: result retain count is correct
  // Verify: no leaks, no crashes
}

// Test 2: Returning autoreleased objects
- (id)createObject __attribute__((objc_direct)) {
  return [[NSObject alloc] init];  // Returns +1 object
}

void testAutorelease(MyClass *obj) {
  @autoreleasepool {
    id result = [obj createObject];
    // Verify: object is properly autoreleased
    // Verify: no leaks after pool drain
  }
}

// Test 3: __bridge casts and ownership transfers
- (void)cfMethod:(CFTypeRef)cfObj __attribute__((objc_direct)) {
  id obj = (__bridge id)cfObj;
  // Verify: bridging works correctly through thunk
}
```

2. **Instrument with ARC Optimizer**:
```bash
# Compile with ARC optimizer logging enabled
clang -fobjc-arc -fobjc-expose-direct-methods \
  -Xclang -arcmt-migrate-report-output=/tmp/arc-report.txt \
  test.m -o test

# Verify ARC optimizer doesn't complain about thunks
# Check for warnings like "unable to optimize retain/release"
```

3. **Memory Analysis Tools**:
```bash
# Run with Instruments (Darwin only)
# - Allocations: detect leaks
# - Zombies: detect use-after-free
# - Leaks: comprehensive leak detection

# Run with Address Sanitizer
clang -fobjc-arc -fobjc-expose-direct-methods -fsanitize=address test.m
./a.out

# Run with Memory Sanitizer (detect uninitialized memory)
clang -fobjc-arc -fobjc-expose-direct-methods -fsanitize=memory test.m
./a.out
```

#### 5.2: Darwin Executable Tests (CRITICAL)

**Why Darwin Testing is Essential**:
- Objective-C runtime behavior differs between platforms
- Apple's ObjC runtime has specific requirements for:
  - Method dispatch
  - Class realization
  - Weak linking
  - ARC integration
- LLVM IR correctness ≠ runtime correctness
- Need to test on actual macOS/iOS/tvOS/watchOS

**Setup Darwin Test Environment**:
```bash
# Minimum requirements:
# - macOS 10.15+ (for modern ObjC runtime)
# - Xcode with command line tools
# - arm64 Mac (for musttail testing) or x86_64

# Build clang on Darwin
cd llvm-project
mkdir build-darwin
cd build-darwin

cmake -G Ninja ../llvm \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_TARGETS_TO_BUILD="AArch64;X86"

ninja clang
```

**Executable Test Suite**:

1. **Basic Functionality Tests** (`test-exec-basic.m`):
```objc
// Compile and run on Darwin
// RUN: %clang -fobjc-arc -fobjc-expose-direct-methods %s -o %t
// RUN: %t

#import <Foundation/Foundation.h>
#import <assert.h>

@interface TestClass : NSObject
- (int)directMethod:(int)x __attribute__((objc_direct));
+ (int)classDirectMethod:(int)x __attribute__((objc_direct));
@end

@implementation TestClass
- (int)directMethod:(int)x {
  return x * 2;
}

+ (int)classDirectMethod:(int)x {
  return x * 3;
}
@end

int main() {
  @autoreleasepool {
    // Test 1: Non-null receiver
    TestClass *obj = [[TestClass alloc] init];
    assert([obj directMethod:5] == 10);

    // Test 2: Null receiver (should return 0)
    TestClass *nilObj = nil;
    assert([nilObj directMethod:5] == 0);

    // Test 3: Class method
    assert([TestClass classDirectMethod:5] == 15);

    NSLog(@"✅ All basic tests passed");
  }
  return 0;
}
```

2. **ARC Runtime Tests** (`test-exec-arc.m`):
```objc
#import <Foundation/Foundation.h>
#import <assert.h>

@interface ARCTest : NSObject
@property (nonatomic, strong) id strongProp;
- (id)returnObject:(id)input __attribute__((objc_direct));
- (void)consumeObject:(id __attribute__((ns_consumed)))input
    __attribute__((objc_direct));
@end

@implementation ARCTest
- (id)returnObject:(id)input {
  return input;  // Should maintain retain count
}

- (void)consumeObject:(id __attribute__((ns_consumed)))input {
  self.strongProp = input;  // Should consume the input
}
@end

static int deallocCount = 0;

@interface Tracked : NSObject
@end

@implementation Tracked
- (void)dealloc {
  deallocCount++;
  // No [super dealloc] in ARC
}
@end

int main() {
  @autoreleasepool {
    ARCTest *test = [[ARCTest alloc] init];

    // Test 1: Object should survive thunk
    @autoreleasepool {
      Tracked *obj1 = [[Tracked alloc] init];
      id result = [test returnObject:obj1];
      assert(result == obj1);
      assert(deallocCount == 0);  // Should not be deallocated yet
    }
    // After inner pool drains
    assert(deallocCount == 1);  // Should be deallocated now

    // Test 2: ns_consumed attribute through thunk
    deallocCount = 0;
    Tracked *obj2 = [[Tracked alloc] init];
    [test consumeObject:obj2];
    assert(test.strongProp == obj2);  // Should be stored
    test.strongProp = nil;
    assert(deallocCount == 1);  // Should be deallocated

    // Test 3: Nil receiver with ARC
    ARCTest *nilTest = nil;
    id result = [nilTest returnObject:[[Tracked alloc] init]];
    assert(result == nil);
    // Object should be released (deallocCount++)

    NSLog(@"✅ All ARC tests passed");
  }
  return 0;
}
```

3. **Struct Return Tests** (`test-exec-struct.m`):
```objc
#import <Foundation/Foundation.h>
#import <assert.h>
#import <string.h>

struct Point {
  int x, y;
};

struct LargeStruct {
  int data[100];
};

@interface StructTest : NSObject
- (struct Point)getPoint __attribute__((objc_direct));
- (struct LargeStruct)getLargeStruct __attribute__((objc_direct));
@end

@implementation StructTest
- (struct Point)getPoint {
  return (struct Point){.x = 42, .y = 84};
}

- (struct LargeStruct)getLargeStruct {
  struct LargeStruct s;
  memset(&s, 0, sizeof(s));
  s.data[0] = 123;
  s.data[99] = 456;
  return s;
}
@end

int main() {
  @autoreleasepool {
    StructTest *obj = [[StructTest alloc] init];

    // Test 1: Small struct (not sret)
    struct Point p = [obj getPoint];
    assert(p.x == 42);
    assert(p.y == 84);

    // Test 2: Large struct (sret)
    struct LargeStruct ls = [obj getLargeStruct];
    assert(ls.data[0] == 123);
    assert(ls.data[99] == 456);

    // Test 3: Nil receiver returns zero-initialized
    StructTest *nilObj = nil;
    struct Point p2 = [nilObj getPoint];
    assert(p2.x == 0);
    assert(p2.y == 0);

    struct LargeStruct ls2 = [nilObj getLargeStruct];
    assert(ls2.data[0] == 0);
    assert(ls2.data[99] == 0);

    NSLog(@"✅ All struct return tests passed");
  }
  return 0;
}
```

4. **Variadic Method Tests** (`test-exec-varargs.m`):
```objc
#import <Foundation/Foundation.h>
#import <assert.h>
#import <stdarg.h>

@interface VarArgsTest : NSObject
- (int)sumInts:(int)count, ... __attribute__((objc_direct));
+ (NSString *)format:(NSString *)fmt, ... __attribute__((objc_direct));
@end

@implementation VarArgsTest
- (int)sumInts:(int)count, ... {
  va_list args;
  va_start(args, count);

  int sum = 0;
  for (int i = 0; i < count; i++) {
    sum += va_arg(args, int);
  }

  va_end(args);
  return sum;
}

+ (NSString *)format:(NSString *)fmt, ... {
  va_list args;
  va_start(args, fmt);
  NSString *result = [[NSString alloc] initWithFormat:fmt arguments:args];
  va_end(args);
  return result;
}
@end

int main() {
  @autoreleasepool {
    VarArgsTest *obj = [[VarArgsTest alloc] init];

    // Test 1: Variadic instance method
    int sum = [obj sumInts:3, 10, 20, 30];
    assert(sum == 60);

    // Test 2: Variadic class method
    NSString *str = [VarArgsTest format:@"Hello %@ %d", @"World", 42];
    assert([str isEqualToString:@"Hello World 42"]);

    // Test 3: Nil receiver (inline nil check should return 0)
    VarArgsTest *nilObj = nil;
    int sum2 = [nilObj sumInts:3, 10, 20, 30];
    assert(sum2 == 0);

    NSLog(@"✅ All variadic method tests passed");
  }
  return 0;
}
```

5. **Cross-TU Tests** (multiple files):

**header.h**:
```objc
#import <Foundation/Foundation.h>

@interface CrossTUTest : NSObject
- (int)externalMethod:(int)x __attribute__((objc_direct));
@end
```

**implementation.m**:
```objc
#import "header.h"

@implementation CrossTUTest
- (int)externalMethod:(int)x {
  return x * 10;
}
@end
```

**caller.m**:
```objc
#import "header.h"
#import <assert.h>

int main() {
  @autoreleasepool {
    CrossTUTest *obj = [[CrossTUTest alloc] init];

    // Cross-TU call - should use thunk (generated in caller.m)
    int result = [obj externalMethod:5];
    assert(result == 50);

    // Nil receiver
    CrossTUTest *nilObj = nil;
    int result2 = [nilObj externalMethod:5];
    assert(result2 == 0);

    NSLog(@"✅ Cross-TU test passed");
  }
  return 0;
}
```

**Compile and link**:
```bash
clang -fobjc-arc -fobjc-expose-direct-methods \
  -c implementation.m -o implementation.o
clang -fobjc-arc -fobjc-expose-direct-methods \
  -c caller.m -o caller.o
clang -fobjc-arc -framework Foundation \
  implementation.o caller.o -o cross_tu_test
./cross_tu_test
```

#### 5.3: Property Accessor Validation

**Direct Properties**:
```objc
@interface PropertyTest : NSObject
@property (nonatomic, direct) int directValue;
@property (nonatomic, direct, readonly) id directObject;
@property (nonatomic) int normalValue;  // For comparison
@end

@implementation PropertyTest
@end

int main() {
  @autoreleasepool {
    PropertyTest *obj = [[PropertyTest alloc] init];

    // Test direct property setters/getters
    obj.directValue = 42;
    assert(obj.directValue == 42);

    // Test nil receiver
    PropertyTest *nilObj = nil;
    nilObj.directValue = 99;  // Should no-op
    assert(nilObj.directValue == 0);  // Should return 0

    NSLog(@"✅ Property accessor tests passed");
  }
  return 0;
}
```

#### 5.4: Weak-Linked Class Tests (Darwin-Specific)

**Setup**:
```bash
# Create a weak-linked framework
# In WeakFramework:
@interface WeakLinkedClass : NSObject
+ (int)weakClassMethod __attribute__((objc_direct));
@end

@implementation WeakLinkedClass
+ (int)weakClassMethod {
  return 123;
}
@end

# Build framework with weak linkage
clang -dynamiclib -fobjc-arc -fobjc-expose-direct-methods \
  WeakLinkedClass.m -o WeakFramework.dylib \
  -install_name @rpath/WeakFramework.dylib
```

**Test**:
```objc
#import <Foundation/Foundation.h>
#import <assert.h>
#import <dlfcn.h>

// Declare as weak import
__attribute__((weak_import))
@interface WeakLinkedClass : NSObject
+ (int)weakClassMethod __attribute__((objc_direct));
@end

int main() {
  @autoreleasepool {
    // Check if framework is available
    if (WeakLinkedClass != nil) {
      int result = [WeakLinkedClass weakClassMethod];
      assert(result == 123);
      NSLog(@"✅ Weak framework available, test passed");
    } else {
      // Framework not available - should not crash
      int result = [WeakLinkedClass weakClassMethod];
      assert(result == 0);  // Nil check should return 0
      NSLog(@"✅ Weak framework unavailable, nil check worked");
    }
  }
  return 0;
}
```

#### 5.5: Performance and Code Size Validation

**Measure Binary Size**:
```bash
# Compile with and without optimization
clang -fobjc-arc MyApp.m -o without_opt
clang -fobjc-arc -fobjc-expose-direct-methods MyApp.m -o with_opt

# Compare sizes
ls -lh without_opt with_opt

# Analyze code size with Bloaty
bloaty without_opt -- with_opt

# Expected: 5-

---

### Phase 7: Optimize Dispatch Helper Functions ⏸️ **PENDING**

**Objective**: Implement full optimization logic for dispatch helper functions to reduce unnecessary thunk calls and class realizations.

**Rationale**:
- Phase 2 created stub implementations that always return `false` (conservative)
- This phase adds the actual optimization logic based on static analysis
- Performance improvement: eliminate redundant nil checks and class realizations
- Correctness is already guaranteed by Phase 2-6; this phase only improves performance

#### Files Modified:
- `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`

#### Changes:

**Implement `isObjCReceiverNonNull()` with heuristics** (`CodeGenModule.cpp`):

```cpp
bool CodeGenModule::isObjCReceiverNonNull(const Expr *receiverExpr,
                                          CodeGenFunction &CGF) const {
  if (!receiverExpr)
    return false;

  receiverExpr = receiverExpr->IgnoreParenCasts();
  QualType type = receiverExpr->getType();

  // Heuristic 1: _Nonnull attribute
  if (auto Nullability = type->getNullability()) {
    if (*Nullability == NullabilityKind::NonNull)
      return true;
  }

  // Heuristic 2: 'self' in instance methods
  if (auto declRef = dyn_cast<DeclRefExpr>(receiverExpr)) {
    if (auto PD = dyn_cast<ImplicitParamDecl>(declRef->getDecl())) {
      if (auto OMD = dyn_cast_or_null<ObjCMethodDecl>(CGF.CurCodeDecl)) {
        if (OMD->getSelfDecl() == PD && OMD->isInstanceMethod())
          return true;
      }
    }
  }

  // Heuristic 3: 'super' in instance methods
  // super is effectively self (cast to superclass type), so it's non-null
  if (auto Super = dyn_cast<ObjCSuperExpr>(receiverExpr)) {
    return true;
  }

  // Heuristic 4: Class objects (but NOT weak-linked classes)
  // Weakly-linked classes can be nil at runtime if their framework is unavailable
  if (type->isObjCClassType() || type->isObjCQualifiedClassType()) {
    // Check if this is a weakly-linked class
    if (auto *IFace = type->getAsObjCInterfaceType()) {
      if (auto *Decl = IFace->getDecl()) {
        // If the class is weakly linked, it may be nil at runtime
        if (Decl->isWeakImported())
          return false;  // Conservative: must use thunk for nil check
      }
    }
    // Non-weak-linked class objects are always non-null after initialization
    return true;
  }

  // Heuristic 5: Results of alloc/new (future enhancement)
  // TODO: Recognize [[Class alloc] init] patterns
  // Pattern: ObjCMessageExpr with selector "alloc" or "new"

  // Heuristic 6: ObjC literals (future enhancement)
  // TODO: Recognize @"string", @[], @{}, @42, etc.
  // Check if expression is ObjCStringLiteral, ObjCArrayLiteral, etc.

  // Heuristic 7: Methods known to return non-null (future enhancement)
  // TODO: Track methods with _Nonnull return types
  // Would require data flow analysis to track return values

  return false;
}
```

**Implement `canClassObjectBeUnrealized()` with heuristics** (`CodeGenModule.cpp`):

```cpp
bool CodeGenModule::canClassObjectBeUnrealized(const ObjCInterfaceDecl *ClassDecl,
                                               CodeGenFunction &CGF) const {
  if (!ClassDecl)
    return false;

  // Heuristic 1: Check if an instance method on the same class was called
  // in a dominating path
  //
  // Implementation approach:
  // - Walk backwards through the current BasicBlock
  // - Check if any call instruction is a direct method call to an instance method
  //   on the same class (or a superclass)
  // - If found in a dominating block, the class must be realized
  //
  // IMPORTANT: Inheritance care is needed:
  // - [Parent foo] realizes Parent, but does NOT realize Child
  // - Only calls to instance methods on ClassDecl or its superclasses help
  // - Calls to instance methods on subclasses do NOT help

  llvm::BasicBlock *CurrentBlock = CGF.Builder.GetInsertBlock();
  if (!CurrentBlock)
    return false;

  // Simple heuristic: Check the current basic block for dominating calls
  // Walk backwards through instructions in the current block
  for (auto II = CurrentBlock->rbegin(), IE = CurrentBlock->rend();
       II != IE; ++II) {
    llvm::Instruction *Inst = &*II;

    // Check if this is a call instruction
    if (auto *Call = dyn_cast<llvm::CallInst>(Inst)) {
      llvm::Function *CalledFunc = Call->getCalledFunction();
      if (!CalledFunc)
        continue;

      // Check if this is a direct method call
      // Direct methods have names like "-[ClassName methodName]"
      llvm::StringRef FuncName = CalledFunc->getName();

      // Parse the function name to extract class information
      // Format: "-[ClassName methodName]" for instance methods
      if (FuncName.startswith("-[")) {
        // Extract the class name from the symbol
        size_t ClassStart = 2; // After "-["
        size_t ClassEnd = FuncName.find(' ', ClassStart);
        if (ClassEnd == llvm::StringRef::npos)
          continue;

        llvm::StringRef CalledClassName =
            FuncName.slice(ClassStart, ClassEnd);

        // Check if the called class matches or is a superclass of ClassDecl
        // IMPORTANT: [Parent foo] does NOT realize Child
        //            Only [Child foo] or [Parent foo] realizes Parent
        llvm::StringRef TargetClassName = ClassDecl->getName();

        if (CalledClassName == TargetClassName) {
          // Found an instance method call on the same class
          // The class must be realized by this point
          return true;
        }

        // Check if CalledClassName is a superclass of ClassDecl
        // This is conservative: if we called a superclass instance method,
        // the superclass is realized, which means our class should be too
        const ObjCInterfaceDecl *Super = ClassDecl->getSuperClass();
        while (Super) {
          if (CalledClassName == Super->getName())
            return true;
          Super = Super->getSuperClass();
        }
      }
    }
  }

  // Heuristic 2: Check dominating blocks (advanced, future enhancement)
  // TODO: Use LLVM's DominatorTree to check if any dominating block
  //       contains a realizing call
  // This would require access to CGF's function-level analysis

  // Heuristic 3: Explicit class realization (future enhancement)
  // TODO: Detect patterns like:
  //   (void)[MyClass self];  // Explicit realization
  //   [MyClass alloc];        // Also realizes the class

  // Conservative default: assume class is not realized
  return false;
}
```

#### Heuristics Summary:

**For `isObjCReceiverNonNull` (Instance Methods):**

| Heuristic | Description | Implementation Status |
|-----------|-------------|----------------------|
| `_Nonnull` attribute | Receiver type has `_Nonnull` annotation | ✅ Phase 7 |
| `self` parameter | Receiver is `self` in instance method | ✅ Phase 7 |
| `super` keyword | Receiver is `super` (implicitly non-null) | ✅ Phase 7 |
| Class objects | Receiver is a non-weak-linked class | ✅ Phase 7 |
| `alloc`/`new` results | Pattern: `[[Class alloc] init]` | 🔮 Future |
| ObjC literals | `@"string"`, `@[]`, `@{}`, `@42` | 🔮 Future |
| Known non-null methods | Methods with `_Nonnull` return type | 🔮 Future |
| LLVM-level analysis | Use `isKnownNonZero()` at IR level | 🔮 Future |

**For `canClassObjectBeUnrealized` (Class Methods):**

| Heuristic | Description | Implementation Status |
|-----------|-------------|----------------------|
| Instance method dominates | Instance method call on same class in dominating path | ✅ Phase 7 (basic) |
| Dominator tree analysis | Use LLVM's DominatorTree for better precision | 🔮 Future |
| Explicit realization | Pattern: `(void)[MyClass self]` or `[MyClass alloc]` | 🔮 Future |
| Inheritance awareness | Careful: `[Parent foo]` does NOT realize `Child` | ✅ Phase 7 |

#### Key Design Considerations:

**1. Inheritance Care for Class Realization:**
From the RFC:
> "Extra care needs to be applied for class methods, e.g. even if [Parent foo] dominates [Child foo], the call to [Child foo] still needs to go through class realization to make sure Child is realized."

This means:
- `[Parent instanceMethod]` realizes **only** `Parent` (and its superclasses)
- `[Child classMethod]` needs its own realization check
- Cannot assume child classes are realized when parent is realized

**2. Weak-Linked Classes:**
- Only weak-linked classes can be `nil` at runtime
- Check with `Decl->isWeakImported()`
- Non-weak-linked class objects are always non-null after initialization

**3. Conservative Approach:**
- When in doubt, return `false` (use thunk)
- False negatives (missed optimization) are acceptable
- False positives (skipping needed nil check) are **NOT** acceptable

**4. Future Optimization - Intrinsic-Based Realization:**
From the RFC:
> "A future optimization could replace the opaque [self self] call in CodeGen with a new LLVM intrinsic (e.g., @llvm.objc.realize.class). A backend optimizer pass (like CSE or GVN) could then safely deduplicate or remove redundant realization calls."

This would allow LLVM optimization passes to:
- Eliminate redundant `[self self]` calls across multiple direct methods
- Common Subexpression Elimination (CSE) for class realization
- Currently impossible due to opaque function call semantics

#### Testing Strategy:

**Test 1: Non-null receiver optimization**
```objc
// Should NOT use thunk (self is non-null)
// CHECK-LABEL: @"-[Class caller]"
// CHECK: call {{.*}} @"-[Class method]"
// CHECK-NOT: _thunk
- (int)caller {
  return [self directMethod];  // self is non-null
}
```

**Test 2: _Nonnull annotation**
```objc
// Should NOT use thunk (_Nonnull receiver)
// CHECK: call {{.*}} @"-[Class method]"
// CHECK-NOT: _thunk
int caller(MyClass *_Nonnull obj) {
  return [obj directMethod];
}
```

**Test 3: Nullable receiver**
```objc
// Should use thunk (nullable receiver)
// CHECK: call {{.*}} @"-[Class method]_thunk"
int caller(MyClass *obj) {
  return [obj directMethod];
}
```

**Test 4: Class method with dominating instance call**
```objc
// Instance method realizes the class
// Class method should NOT need thunk
// CHECK-LABEL: @testClassRealized
// CHECK: call {{.*}} @"-[Class instanceMethod]"
// CHECK: call {{.*}} @"+[Class classMethod]"
// CHECK-NOT: _thunk
int testClassRealized(MyClass *obj) {
  [obj instanceMethod];  // Realizes MyClass
  return [MyClass classMethod];  // Class is already realized
}
```

**Test 5: Inheritance - parent does not realize child**
```objc
@interface Parent : NSObject
+ (int)parentClassMethod __attribute__((objc_direct));
@end

@interface Child : Parent
+ (int)childClassMethod __attribute__((objc_direct));
@end

// Parent realization does NOT realize Child
// CHECK-LABEL: @testInheritance
// CHECK: call {{.*}} @"+[Parent parentClassMethod]"
// CHECK: call {{.*}} @"+[Child childClassMethod]_thunk"
int testInheritance(Parent *parentObj) {
  [Parent parentClassMethod];  // Realizes Parent only
  return [Child childClassMethod];  // Child needs realization
}
```

#### Validation:
```bash
# Build with optimization enabled
ninja -C build-debug clang

# Run all tests with expose-direct-method prefix
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang

# Verify optimizations are working:
# - Non-null receivers call implementation directly (no thunk)
# - Nullable receivers call thunk
# - Class methods skip realization when possible
```

#### Performance Metrics:

After implementing Phase 7, measure:
1. **Binary size reduction**: Compare binary size with/without optimizations
2. **Thunk call reduction**: Count how many calls skip thunks
3. **Class realization reduction**: Count eliminated `[self self]` calls

Expected improvements:
- ~10-30% reduction in thunk calls (depends on code patterns)
- Smaller binary size due to reduced thunk overhead
- No performance regression (optimizations only)

---

## Files to Modify

### Summary of All Files

| File | Phases | Purpose |
|------|--------|---------|
| `clang/include/clang/Basic/CodeGenOptions.def` | 0 | Add ObjCNilCheckThunk option |
| `clang/include/clang/Driver/Options.td` | 0 | Add compiler flag |
| `clang/include/clang/AST/DeclObjC.h` | 1 | Add canHaveNilCheckThunk() |
| `clang/lib/CodeGen/CodeGenModule.h` | 1, 2 | Add optimization checks, nullability helpers |
| `clang/lib/CodeGen/CodeGenModule.cpp` | 1, 2, 7 | Implement helper functions |
| `clang/lib/CodeGen/CodeGenFunction.h` | 3 | Add StartObjCDirectThunk/FinishObjCDirectThunk |
| `clang/lib/CodeGen/CGObjCRuntime.h` | 1, 2 | Refactor symbol name generation, add virtual dispatch helpers |
| `clang/lib/CodeGen/CGObjCRuntime.cpp` | 1, 2 | Implement symbol name generation and stub dispatch helpers |
| `clang/lib/CodeGen/CGObjCMac.cpp` | 1, 3 | Modify implementation generation, add thunk generation |
| `clang/lib/CodeGen/CGObjC.cpp` | 1, 4 | Update visibility, integrate call site logic |
| `clang/test/CodeGenObjC/expose-direct-method*.m` | 1, 2, 3, 6 | Add comprehensive tests (all prefixed with expose-direct-method) |

### Detailed File Descriptions

#### `/home/peterrong/llvm-project/clang/include/clang/Basic/CodeGenOptions.def`
- **Phase**: 0
- **Changes**: Add `CODEGENOPT(ObjCNilCheckThunk, 1, 0, Benign)`
- **Purpose**: Enable/disable feature via compiler flag

#### `/home/peterrong/llvm-project/clang/include/clang/Driver/Options.td`
- **Phase**: 0
- **Changes**: Add `-fobjc-direct-caller-thunks` flag definition
- **Purpose**: Command-line interface for the feature

#### `/home/peterrong/llvm-project/clang/include/clang/AST/DeclObjC.h`
- **Phase**: 1
- **Changes**: Add `canHaveNilCheckThunk()` method to `ObjCMethodDecl`
- **Purpose**: Determine if a method is eligible for optimization

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.h`
- **Phase**: 1, 2, 3
- **Changes**:
  - Add `shouldHaveNilCheckThunk()` (Phase 1)
  - Add `isObjCReceiverNonNull()` (Phase 2)
  - Add `ObjCDirectThunks` cache and `getOrCreateObjCDirectThunk()` (Phase 3)
- **Purpose**: Centralize optimization logic

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CodeGenModule.cpp`
- **Phase**: 1, 2, 3
- **Changes**: Implement functions declared in CodeGenModule.h
- **Purpose**: Implementation of core optimization logic

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCRuntime.h`
- **Phase**: 1
- **Changes**: Add `includePrefixByte` parameter to `getSymbolNameForMethod()`
- **Purpose**: Allow removing `\01` prefix for public symbols

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCRuntime.cpp`
- **Phase**: 1
- **Changes**: Implement modified `getSymbolNameForMethod()`
- **Purpose**: Generate public symbols when optimization enabled

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjCMac.cpp`
- **Phase**: 1, 3
- **Changes**:
  - Modify `GenerateDirectMethod()` (Phase 1)
  - Modify `GenerateDirectMethodPrologue()` (Phase 1)
  - Add thunk generation logic (Phase 3)
- **Purpose**: Generate implementations and thunks

#### `/home/peterrong/llvm-project/clang/lib/CodeGen/CGObjC.cpp`
- **Phase**: 1, 4
- **Changes**:
  - Update visibility settings (Phase 1)
  - Integrate call site logic (Phase 4)
- **Purpose**: Determine whether to call implementation or thunk

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method.m`
- **Phase**: 1, 6
- **Changes**: Add/update comprehensive tests for main functionality
- **Purpose**: Verify optimization works correctly

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-disabled.m`
- **Phase**: 1
- **Changes**: Test backward compatibility
- **Purpose**: Ensure old behavior without flag

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-varargs.m`
- **Phase**: 1
- **Changes**: Test variadic method exclusion
- **Purpose**: Verify variadic methods keep old behavior

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-nullability.m`
- **Phase**: 2
- **Changes**: Test nullability analysis
- **Purpose**: Verify correct detection of non-null receivers

#### `/home/peterrong/llvm-project/clang/test/CodeGenObjC/expose-direct-method-thunks.m`
- **Phase**: 3, 6
- **Changes**: Test thunk generation and structure
- **Purpose**: Verify thunks are generated correctly with musttail calls

---

## Testing Strategy

### Levels of Testing

**1. Unit Tests (Per Phase)**
- Test each phase independently
- Verify no regressions in existing tests
- Use XFAIL for incomplete features

**2. Integration Tests**
- Test complete workflow after all phases
- Test interaction between phases
- Verify end-to-end behavior

**3. Regression Tests**
- Run existing direct method tests
- Verify backward compatibility
- Test with flag disabled

**4. Edge Case Tests**
- Variadic methods
- ARC compatibility
- Struct returns
- Weak-linked classes
- Properties

### Test Execution

```bash
# Build clang
ninja -C build-debug clang
```bash
# Run all tests with expose-direct-method prefix (RECOMMENDED)
LIT_FILTER=expose-direct-method ninja -C build-debug check-clang

# Run all ObjC CodeGen tests
ninja -C build-debug check-clang-codegen-objc

# Run specific test file
./build-debug/bin/llvm-lit -v clang/test/CodeGenObjC/expose-direct-method.m

# Run with verbose output and print IR
./build-debug/bin/llvm-lit -v -a clang/test/CodeGenObjC/expose-direct-method-thunks.m
```

### Manual Testing

```bash
# Compile test file with optimization enabled
./build-debug/bin/clang -cc1 -emit-llvm -fobjc-arc \
  -fobjc-expose-direct-methods -triple x86_64-apple-darwin10 \
  test.m -o - | less

# Check for expected patterns:
# - Public symbols: @"-[Class method]" (no \01)
# - Thunks: @"-[Class method]_thunk"
# - No nil checks in implementations
# - Musttail calls in thunks

# Compile without flag (backward compatibility)
./build-debug/bin/clang -cc1 -emit-llvm -fobjc-arc \
  -triple x86_64-apple-darwin10 test.m -o - | less

# Check for old behavior:
# - Hidden symbols: @"\01-[Class method]"
# - Nil checks in implementations
# - No thunks
```

### Performance Testing

**Code Size Measurement:**
```bash
# Compile large ObjC project with/without optimization
# Compare binary sizes

# With optimization
clang -fobjc-expose-direct-methods project.m -o with_opt

# Without optimization
clang project.m -o without_opt

# Compare sizes
ls -lh with_opt without_opt
```

**Expected Results:**
- Smaller binary size (eliminated redundant nil checks)
- Fewer function calls from non-null sites
- No performance regression

---

## Build and Validation

### Initial Setup

```bash
# Clone or update llvm-project
cd /home/peterrong/llvm-project

# Create build directory
mkdir -p build-debug
cd build-debug

# Configure with CMake
cmake -G Ninja ../llvm \
  -DCMAKE_BUILD_TYPE=Debug \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

# Build clang
ninja clang
```

### Incremental Build After Changes

```bash
# After modifying source files
cd build-debug

# Build clang (incremental)
ninja clang

# Run tests
ninja check-clang-codegen-objc
```

### Validation Checklist

After each phase:

- [ ] Code compiles without errors
- [ ] Code compiles without warnings
- [ ] Existing tests pass
- [ ] New tests pass (or XFAIL'd appropriately)
- [ ] No memory leaks (run with ASAN)
- [ ] Code review ready

### Debugging Tips

**1. Print LLVM IR:**
```bash
./build-debug/bin/clang -cc1 -emit-llvm -fobjc-arc \
  -fobjc-direct-caller-thunks -triple x86_64-apple-darwin10 \
  test.m -o test.ll

# View IR
less test.ll
```

**2. Enable verbose output:**
```bash
./build-debug/bin/clang -cc1 -emit-llvm -fobjc-arc \
  -fobjc-direct-caller-thunks -triple x86_64-apple-darwin10 \
  -debug test.m -o test.ll 2>&1 | less
```

**3. Use lldb to debug compiler:**
```bash
lldb ./build-debug/bin/clang

# Set breakpoint
(lldb) b CodeGenModule::getOrCreateObjCDirectThunk

# Run with arguments
(lldb) run -cc1 -emit-llvm test.m -o -
```

**4. Check for memory issues:**
```bash
# Build with ASAN
cmake -G Ninja ../llvm \
  -DCMAKE_BUILD_TYPE=Debug \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_USE_SANITIZER=Address

ninja clang

# Run tests with ASAN
ninja check-clang-codegen-objc
```

---

## Implementation Timeline

### Estimated Effort

| Phase | Effort | Dependencies |
|-------|--------|--------------|
| Phase 0: Infrastructure | 1-2 hours | None | ✅ Complete |
| Phase 1: Implementation Gen | 1-2 days | Phase 0 | ✅ Complete |
| Phase 2: Stub Dispatch Helpers | 1 day | Phase 1 | ✅ Complete |
| Phase 3: Thunk Generation | 2-3 days | Phases 1, 2 | ✅ Complete |
| Phase 4: Call Site Logic | 1-2 days | Phases 1, 2, 3 | 🚧 In Progress |
| Phase 5: Special Cases | 1 day | Phase 4 | ⏸️ Pending |
| Phase 6: Tests | 1-2 days | All phases | ⏸️ Pending |
| Phase 7: Optimize Dispatch | 1-2 days | All phases | ⏸️ Pending |
| **Total** | **1.5-2 weeks** | | ~60% Complete |

### Milestones

**Milestone 1: Infrastructure Complete** (Phases 0-1)
- Compiler flag works
- Implementation generation modified
- Backward compatibility maintained

**Milestone 2: Analysis Ready** (Phase 2)
- Nullability analysis implemented
- Ready for thunk generation

**Milestone 3: Thunk Generation** (Phase 3)
- Thunks generated correctly
- Musttail calls working
- Linkonce_odr deduplication verified

**Milestone 4: Integration Complete** (Phase 4)
- Call sites use correct target
- Non-null → implementation
- Nullable → thunk

**Milestone 5: Production Ready** (Phases 5-6)
- All edge cases handled
- Comprehensive tests pass
- Performance validated
- Ready for code review

---

## References

### Design Documents
- RFC: "Optimizing Code Size of objc_direct by Exposing Function Symbols and Moving Nil Checks to Thunks"
- Google Doc: https://docs.google.com/document/d/1uq7-4z_3O2G3g6tQFsVExSWnDY_VXSc8e9izZho6uVM/

### Previous Implementation
- Failed implementation patch: `/home/peterrong/llvm-project/prevImplement.patch`
- Phases 0-2.5 completed, Phases 3-6 pending

### Key Code Locations
- Direct method generation: `clang/lib/CodeGen/CGObjCMac.cpp`
- Message send emission: `clang/lib/CodeGen/CGObjC.cpp`
- Runtime interface: `clang/lib/CodeGen/CGObjCRuntime.{h,cpp}`
- AST declarations: `clang/include/clang/AST/DeclObjC.h`

### LLVM Documentation
- MustTail calls: https://llvm.org/docs/LangRef.html#call-instruction
- Linkonce_odr linkage: https://llvm.org/docs/LangRef.html#linkage-types
- Function attributes: https://llvm.org/docs/LangRef.html#function-attributes

### Related Work
- Previous diff: D126639 (two-symbol approach)
- ObjC direct methods: https://nshipster.com/direct/

---

## Appendix

### Glossary

- **objc_direct**: Attribute that makes ObjC methods use direct calls instead of message dispatch
- **Thunk**: Small wrapper function that performs nil check before calling implementation
- **NeXT runtime**: Modern Objective-C runtime (as opposed to GNU runtime)
- **Musttail call**: LLVM instruction that guarantees tail call (no stack frame)
- **LinkOnceODR**: Linkage type that allows linker to deduplicate identical definitions
- **SRet**: Struct return calling convention for large return types
- **ARC**: Automatic Reference Counting for memory management

### Common Issues and Solutions

**Issue: Musttail call fails verification**
- Cause: Return type mismatch or calling convention mismatch
- Solution: Ensure thunk signature exactly matches implementation

**Issue: Linker error "duplicate symbol"**
- Cause: Multiple implementations with same name
- Solution: Verify external linkage is used, not linkonce_odr for implementations

**Issue: ARC crashes with thunks**
- Cause: Thunk not using musttail, ARC operations between thunk and impl
- Solution: Always use musttail for thunk → implementation call

**Issue: Nil check not eliminated**
- Cause: Nullability analysis not detecting non-null receiver
- Solution: Enhance isObjCReceiverNonNull() with more cases

**Issue: Variadic methods crash**
- Cause: Attempting to use thunk for variadic methods
- Solution: Verify canHaveNilCheckThunk() excludes variadic

---

## Next Steps

1. **Review this plan** with team for feedback
2. **Set up development environment** with debug build
3. **Start with Phase 0** (if not already done)
4. **Proceed sequentially** through phases
5. **Test thoroughly** after each phase
6. **Submit for code review** after Milestone 5
