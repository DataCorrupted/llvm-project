//===- DWARFVerifierTest.cpp ----------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/DebugInfo/DWARF/DWARFVerifier.h"
#include "llvm/DebugInfo/DWARF/DWARFAddressRange.h"
#include "gtest/gtest.h"
#include <chrono>
#include <random>

using namespace llvm;

namespace {

using DieRangeInfo = DWARFVerifier::DieRangeInfo;

// Helper to create a DieRangeInfo with a single range [Lo, Hi).
DieRangeInfo makeRI(uint64_t Lo, uint64_t Hi) {
  return DieRangeInfo({{Lo, Hi}});
}

//===----------------------------------------------------------------------===//
// Correctness tests
//===----------------------------------------------------------------------===//

TEST(DWARFVerifierTest, InsertNoOverlap) {
  DieRangeInfo Parent;
  // Insert three non-overlapping ranges.
  EXPECT_EQ(Parent.insert(makeRI(100, 200)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(300, 400)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(500, 600)), Parent.Children.end());
  EXPECT_EQ(Parent.Children.size(), 3u);
}

TEST(DWARFVerifierTest, InsertOverlapWithPredecessor) {
  DieRangeInfo Parent;
  EXPECT_EQ(Parent.insert(makeRI(100, 300)), Parent.Children.end());
  // Overlaps with [100, 300).
  auto It = Parent.insert(makeRI(200, 400));
  EXPECT_NE(It, Parent.Children.end());
  // The conflicting child should be the first one.
  EXPECT_EQ(It->Ranges.front().LowPC, 100u);
}

TEST(DWARFVerifierTest, InsertOverlapWithSuccessor) {
  DieRangeInfo Parent;
  EXPECT_EQ(Parent.insert(makeRI(300, 500)), Parent.Children.end());
  // Insert before, overlapping with [300, 500).
  auto It = Parent.insert(makeRI(100, 400));
  EXPECT_NE(It, Parent.Children.end());
  EXPECT_EQ(It->Ranges.front().LowPC, 300u);
}

TEST(DWARFVerifierTest, InsertEmptyRange) {
  DieRangeInfo Parent;
  DieRangeInfo Empty;
  EXPECT_EQ(Parent.insert(Empty), Parent.Children.end());
  EXPECT_EQ(Parent.Children.size(), 0u);
}

TEST(DWARFVerifierTest, InsertAdjacentRanges) {
  DieRangeInfo Parent;
  // Adjacent but not overlapping: [100,200) and [200,300).
  EXPECT_EQ(Parent.insert(makeRI(100, 200)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(200, 300)), Parent.Children.end());
  EXPECT_EQ(Parent.Children.size(), 2u);
}

TEST(DWARFVerifierTest, InsertLongRangeOverlapsSuccessor) {
  DieRangeInfo Parent;
  EXPECT_EQ(Parent.insert(makeRI(100, 200)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(300, 400)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(500, 600)), Parent.Children.end());
  // Insert a long range that overlaps multiple children.
  auto It = Parent.insert(makeRI(150, 550));
  EXPECT_NE(It, Parent.Children.end());
}

TEST(DWARFVerifierTest, InsertBetweenNonOverlapping) {
  DieRangeInfo Parent;
  EXPECT_EQ(Parent.insert(makeRI(100, 200)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(500, 600)), Parent.Children.end());
  // Fits in the gap.
  EXPECT_EQ(Parent.insert(makeRI(300, 400)), Parent.Children.end());
  EXPECT_EQ(Parent.Children.size(), 3u);
}

TEST(DWARFVerifierTest, InsertOverlapByOneAddress) {
  DieRangeInfo Parent;
  EXPECT_EQ(Parent.insert(makeRI(100, 200)), Parent.Children.end());
  // Overlaps by a single address.
  auto It = Parent.insert(makeRI(199, 300));
  EXPECT_NE(It, Parent.Children.end());
}

TEST(DWARFVerifierTest, InsertReverseOrder) {
  DieRangeInfo Parent;
  // Insert in reverse address order.
  EXPECT_EQ(Parent.insert(makeRI(500, 600)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(300, 400)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(100, 200)), Parent.Children.end());
  EXPECT_EQ(Parent.Children.size(), 3u);
}

TEST(DWARFVerifierTest, InsertReverseOrderWithOverlap) {
  DieRangeInfo Parent;
  EXPECT_EQ(Parent.insert(makeRI(500, 600)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(300, 400)), Parent.Children.end());
  // Overlaps with [300, 400).
  auto It = Parent.insert(makeRI(350, 450));
  EXPECT_NE(It, Parent.Children.end());
}

TEST(DWARFVerifierTest, InsertRandomOrderNoOverlap) {
  DieRangeInfo Parent;
  // Insert in shuffled order.
  EXPECT_EQ(Parent.insert(makeRI(500, 600)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(100, 200)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(700, 800)), Parent.Children.end());
  EXPECT_EQ(Parent.insert(makeRI(300, 400)), Parent.Children.end());
  EXPECT_EQ(Parent.Children.size(), 4u);
}

//===----------------------------------------------------------------------===//
// Stress test: O(N^2) -> O(N log N) performance regression test
//===----------------------------------------------------------------------===//

TEST(DWARFVerifierTest, InsertPerformanceForwardOrder) {
  // Insert N non-overlapping ranges in forward address order.
  // With O(N^2): N=100000 would take ~minutes.
  // With O(N log N): should complete in < 1 second.
  const unsigned N = 100000;
  DieRangeInfo Parent;

  auto Start = std::chrono::steady_clock::now();
  for (unsigned I = 0; I < N; ++I) {
    uint64_t Lo = I * 100;
    uint64_t Hi = Lo + 50;
    ASSERT_EQ(Parent.insert(makeRI(Lo, Hi)), Parent.Children.end());
  }
  auto End = std::chrono::steady_clock::now();
  auto ElapsedMs =
      std::chrono::duration_cast<std::chrono::milliseconds>(End - Start)
          .count();

  EXPECT_EQ(Parent.Children.size(), (size_t)N);
  // Should complete well within 10 seconds. The old O(N^2) implementation
  // would take minutes for N=100000.
  EXPECT_LT(ElapsedMs, 10000) << "Insert took " << ElapsedMs
                              << "ms; likely O(N^2) regression for N=" << N;
}

TEST(DWARFVerifierTest, InsertPerformanceReverseOrder) {
  // Insert in reverse order — exercises different code paths.
  const unsigned N = 100000;
  DieRangeInfo Parent;

  auto Start = std::chrono::steady_clock::now();
  for (unsigned I = N; I > 0; --I) {
    uint64_t Lo = I * 100;
    uint64_t Hi = Lo + 50;
    ASSERT_EQ(Parent.insert(makeRI(Lo, Hi)), Parent.Children.end());
  }
  auto End = std::chrono::steady_clock::now();
  auto ElapsedMs =
      std::chrono::duration_cast<std::chrono::milliseconds>(End - Start)
          .count();

  EXPECT_EQ(Parent.Children.size(), (size_t)N);
  EXPECT_LT(ElapsedMs, 10000) << "Insert took " << ElapsedMs
                              << "ms; likely O(N^2) regression for N=" << N;
}

TEST(DWARFVerifierTest, InsertPerformanceRandomOrder) {
  // Insert in random order — most realistic scenario.
  const unsigned N = 100000;
  DieRangeInfo Parent;

  // Generate N non-overlapping ranges, then shuffle.
  std::vector<std::pair<uint64_t, uint64_t>> Ranges;
  Ranges.reserve(N);
  for (unsigned I = 0; I < N; ++I)
    Ranges.push_back({I * 100, I * 100 + 50});

  std::mt19937 RNG(42); // Fixed seed for reproducibility.
  std::shuffle(Ranges.begin(), Ranges.end(), RNG);

  auto Start = std::chrono::steady_clock::now();
  for (const auto &[Lo, Hi] : Ranges)
    ASSERT_EQ(Parent.insert(makeRI(Lo, Hi)), Parent.Children.end());
  auto End = std::chrono::steady_clock::now();
  auto ElapsedMs =
      std::chrono::duration_cast<std::chrono::milliseconds>(End - Start)
          .count();

  EXPECT_EQ(Parent.Children.size(), (size_t)N);
  EXPECT_LT(ElapsedMs, 10000) << "Insert took " << ElapsedMs
                              << "ms; likely O(N^2) regression for N=" << N;
}

TEST(DWARFVerifierTest, InsertPerformanceWithOverlapDetection) {
  // Insert N-1 non-overlapping ranges, then insert one that overlaps.
  // Verify the overlap is detected quickly.
  const unsigned N = 100000;
  DieRangeInfo Parent;

  for (unsigned I = 0; I < N - 1; ++I) {
    uint64_t Lo = I * 100;
    uint64_t Hi = Lo + 50;
    ASSERT_EQ(Parent.insert(makeRI(Lo, Hi)), Parent.Children.end());
  }

  // Insert an overlapping range in the middle.
  auto Start = std::chrono::steady_clock::now();
  uint64_t Mid = (N / 2) * 100;
  auto It = Parent.insert(makeRI(Mid + 10, Mid + 60));
  auto End = std::chrono::steady_clock::now();
  auto ElapsedMs =
      std::chrono::duration_cast<std::chrono::milliseconds>(End - Start)
          .count();

  EXPECT_NE(It, Parent.Children.end()) << "Overlap should be detected";
  EXPECT_LT(ElapsedMs, 100) << "Single overlap detection took " << ElapsedMs
                            << "ms; should be O(log N)";
}

} // namespace
