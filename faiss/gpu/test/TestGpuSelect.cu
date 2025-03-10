/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include <faiss/Index.h>
#include <faiss/gpu/StandardGpuResources.h>
#include <faiss/gpu/test/TestUtils.h>
#include <faiss/gpu/utils/DeviceUtils.h>
#include <gtest/gtest.h>
#include <algorithm>
#include <faiss/gpu/utils/BlockSelectKernel.cuh>
#include <faiss/gpu/utils/DeviceDefs.cuh>
#include <faiss/gpu/utils/DeviceTensor.cuh>
#include <faiss/gpu/utils/HostTensor.cuh>
#include <faiss/gpu/utils/WarpSelectKernel.cuh>
#include <sstream>
#include <unordered_map>
#include <vector>

void testForSize(int rows, int cols, int k, bool dir, bool warp) {
    using namespace faiss;
    using namespace faiss::gpu;

    StandardGpuResources res;

    std::vector<float> v = randVecs(rows, cols);
    HostTensor<float, 2, true> hostVal({rows, cols});

    for (int r = 0; r < rows; ++r) {
        for (int c = 0; c < cols; ++c) {
            hostVal[r][c] = v[r * cols + c];
        }
    }

    // row -> (val -> idx)
    std::unordered_map<int, std::vector<std::pair<int, float>>>
            hostOutValAndInd;
    for (int r = 0; r < rows; ++r) {
        std::vector<std::pair<int, float>> closest;

        for (int c = 0; c < cols; ++c) {
            closest.emplace_back(c, (float)hostVal[r][c]);
        }

        auto dirFalseFn = [](std::pair<int, float>& a,
                             std::pair<int, float>& b) {
            return a.second < b.second;
        };
        auto dirTrueFn = [](std::pair<int, float>& a,
                            std::pair<int, float>& b) {
            return a.second > b.second;
        };

        std::sort(closest.begin(), closest.end(), dir ? dirTrueFn : dirFalseFn);
        hostOutValAndInd.emplace(r, closest);
    }

    // Select top-k on GPU
    DeviceTensor<float, 2, true> gpuVal(
            res.getResources().get(),
            makeDevAlloc(AllocType::Other, 0),
            hostVal);
    DeviceTensor<float, 2, true> gpuOutVal(
            res.getResources().get(),
            makeDevAlloc(AllocType::Other, 0),
            {rows, k});
    DeviceTensor<idx_t, 2, true> gpuOutInd(
            res.getResources().get(),
            makeDevAlloc(AllocType::Other, 0),
            {rows, k});

    if (warp) {
        runWarpSelect(gpuVal, gpuOutVal, gpuOutInd, dir, k, 0);
    } else {
        runBlockSelect(gpuVal, gpuOutVal, gpuOutInd, dir, k, 0);
    }

    // Copy back to CPU
    HostTensor<float, 2, true> outVal(gpuOutVal, 0);
    HostTensor<idx_t, 2, true> outInd(gpuOutInd, 0);

    for (int r = 0; r < rows; ++r) {
        std::unordered_map<idx_t, idx_t> seenIndices;

        for (int i = 0; i < k; ++i) {
            float gpuV = outVal[r][i];
            float cpuV = hostOutValAndInd[r][i].second;

            EXPECT_EQ(gpuV, cpuV)
                    << "rows " << rows << " cols " << cols << " k " << k
                    << " dir " << dir << " row " << r << " ind " << i;

            // If there are identical elements in a row that should be
            // within the top-k, then it is possible that the index can
            // differ, because the order in which the GPU will see the
            // equivalent values is different than the CPU (and will remain
            // unspecified, since this is affected by the choice of
            // k-selection algorithm that we use)
            idx_t gpuInd = outInd[r][i];
            idx_t cpuInd = hostOutValAndInd[r][i].first;

            // We should never see duplicate indices, however
            auto itSeenIndex = seenIndices.find(gpuInd);

            EXPECT_EQ(itSeenIndex, seenIndices.end())
                    << "Row " << r << " user index " << gpuInd
                    << " was seen at both " << itSeenIndex->second << " and "
                    << i;

            seenIndices[gpuInd] = i;

            if (gpuInd != cpuInd) {
                // Gather the values from the original data via index; the
                // values should be the same
                float gpuGatherV = hostVal[r][gpuInd];
                float cpuGatherV = hostVal[r][cpuInd];

                EXPECT_EQ(gpuGatherV, cpuGatherV)
                        << "rows " << rows << " cols " << cols << " k " << k
                        << " dir " << dir << " row " << r << " ind " << i
                        << " source ind " << gpuInd << " " << cpuInd;
            }
        }
    }
}

// General test
TEST(TestGpuSelect, test) {
    for (int i = 0; i < 10; ++i) {
        int rows = faiss::gpu::randVal(10, 100);
        int cols = faiss::gpu::randVal(1, 30000);
        int k = std::min(cols, faiss::gpu::randVal(1, GPU_MAX_SELECTION_K));
        bool dir = faiss::gpu::randBool();

        testForSize(rows, cols, k, dir, false);
    }
}

// Test for k = 1
TEST(TestGpuSelect, test1) {
    for (int i = 0; i < 5; ++i) {
        int rows = faiss::gpu::randVal(10, 100);
        int cols = faiss::gpu::randVal(1, 30000);
        bool dir = faiss::gpu::randBool();

        testForSize(rows, cols, 1, dir, false);
    }
}

// Test for where k = #cols exactly (we are returning all the values,
// just sorted)
TEST(TestGpuSelect, testExact) {
    for (int i = 0; i < 5; ++i) {
        int rows = faiss::gpu::randVal(10, 100);
        int cols = faiss::gpu::randVal(1, GPU_MAX_SELECTION_K);
        bool dir = faiss::gpu::randBool();

        testForSize(rows, cols, cols, dir, false);
    }
}

// General test
TEST(TestGpuSelect, testWarp) {
    for (int i = 0; i < 10; ++i) {
        int rows = faiss::gpu::randVal(10, 100);
        int cols = faiss::gpu::randVal(1, 30000);
        int k = std::min(cols, faiss::gpu::randVal(1, GPU_MAX_SELECTION_K));
        bool dir = faiss::gpu::randBool();

        testForSize(rows, cols, k, dir, true);
    }
}

// Test for k = 1
TEST(TestGpuSelect, test1Warp) {
    for (int i = 0; i < 5; ++i) {
        int rows = faiss::gpu::randVal(10, 100);
        int cols = faiss::gpu::randVal(1, 30000);
        bool dir = faiss::gpu::randBool();

        testForSize(rows, cols, 1, dir, true);
    }
}

// Test for where k = #cols exactly (we are returning all the values,
// just sorted)
TEST(TestGpuSelect, testExactWarp) {
    for (int i = 0; i < 5; ++i) {
        int rows = faiss::gpu::randVal(10, 100);
        int cols = faiss::gpu::randVal(1, GPU_MAX_SELECTION_K);
        bool dir = faiss::gpu::randBool();

        testForSize(rows, cols, cols, dir, true);
    }
}

int main(int argc, char** argv) {
    testing::InitGoogleTest(&argc, argv);

    // just run with a fixed test seed
    faiss::gpu::setTestSeed(100);

    return RUN_ALL_TESTS();
}
