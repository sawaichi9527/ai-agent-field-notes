// HIP 端到端驗證程式：向量相加 + 裝置資訊查詢
// 用於確認 ROCm 10.1.0 在 gfx1151 上可編譯並實際在 GPU 執行
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>

#define CHECK(call)                                                            \
    do {                                                                       \
        hipError_t e = (call);                                                 \
        if (e != hipSuccess) {                                                 \
            printf("HIP ERROR %s:%d -> %s\n", __FILE__, __LINE__,              \
                   hipGetErrorString(e));                                      \
            exit(1);                                                           \
        }                                                                      \
    } while (0)

__global__ void vector_add(const float* a, const float* b, float* c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    int dev = 0;
    CHECK(hipSetDevice(dev));

    hipDeviceProp_t prop;
    CHECK(hipGetDeviceProperties(&prop, dev));
    printf("Device name        : %s\n", prop.name);
    printf("GCN arch name      : %s\n", prop.gcnArchName);
    printf("Compute units      : %d\n", prop.multiProcessorCount);
    printf("Total global mem   : %.1f GiB\n",
           prop.totalGlobalMem / 1024.0 / 1024.0 / 1024.0);
    printf("Warp size          : %d\n", prop.warpSize);
    printf("Unified addressing : %s\n", prop.unifiedAddressing ? "yes" : "no");

    const int n = 1 << 22;  // 4M elements
    const size_t bytes = n * sizeof(float);

    float *ha = (float*)malloc(bytes), *hb = (float*)malloc(bytes),
          *hc = (float*)malloc(bytes);
    for (int i = 0; i < n; i++) { ha[i] = 1.0f; hb[i] = 2.0f; }

    float *da, *db, *dc;
    CHECK(hipMalloc(&da, bytes));
    CHECK(hipMalloc(&db, bytes));
    CHECK(hipMalloc(&dc, bytes));
    CHECK(hipMemcpy(da, ha, bytes, hipMemcpyHostToDevice));
    CHECK(hipMemcpy(db, hb, bytes, hipMemcpyHostToDevice));

    int block = 256, grid = (n + block - 1) / block;
    printf("Launching kernel   : grid=%d block=%d\n", grid, block);

    hipEvent_t t0, t1;
    CHECK(hipEventCreate(&t0));
    CHECK(hipEventCreate(&t1));
    CHECK(hipEventRecord(t0));
    vector_add<<<grid, block>>>(da, db, dc, n);
    CHECK(hipGetLastError());
    CHECK(hipEventRecord(t1));
    CHECK(hipEventSynchronize(t1));
    float ms = 0.0f;
    CHECK(hipEventElapsedTime(&ms, t0, t1));

    CHECK(hipMemcpy(hc, dc, bytes, hipMemcpyDeviceToHost));

    int bad = 0;
    for (int i = 0; i < n; i++) if (fabsf(hc[i] - 3.0f) > 1e-6f) bad++;

    printf("Kernel time        : %.3f ms\n", ms);
    printf("Bandwidth (approx) : %.1f GB/s\n",
           (3.0 * bytes) / (ms / 1000.0) / 1e9);
    printf("Mismatches         : %d / %d\n", bad, n);

    CHECK(hipFree(da)); CHECK(hipFree(db)); CHECK(hipFree(dc));
    free(ha); free(hb); free(hc);

    if (bad == 0) { printf("\nRESULT: PASS ✅\n"); return 0; }
    printf("\nRESULT: FAIL ❌\n");
    return 1;
}
