// bench-vector-add.cpp — 可比性的向量相加頻寬測試（warmup + 多次取樣）
//
// 與 .rocm-verify/hip-vector-add.cpp 的差異：
//   * 該檔只發射 1 次 kernel（含 module load / 時脈拉升），適合「能不能跑」的煙測
//   * 本檔先 warmup 再量 N 次，輸出 min / median / mean，適合版本間 A/B 比較
//
// 用法： ./bench-vector-add [iters]       預設 30 次（warmup 固定 10 次）
#include <hip/hip_runtime.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CHECK(call)                                                            \
    do {                                                                       \
        hipError_t e = (call);                                                 \
        if (e != hipSuccess) {                                                 \
            printf("HIP ERROR %s:%d -> %s\n", __FILE__, __LINE__,              \
                   hipGetErrorString(e));                                      \
            exit(1);                                                           \
        }                                                                      \
    } while (0)

__global__ void vector_add(const float* a, const float* b, float* c, size_t n) {
    size_t i = (size_t)blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

static double median_of(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    size_t m = v.size() / 2;
    return (v.size() % 2) ? v[m] : 0.5 * (v[m - 1] + v[m]);
}

int main(int argc, char** argv) {
    int iters = (argc > 1) ? atoi(argv[1]) : 30;
    if (iters < 3) iters = 3;
    const int warmup = 10;

    hipDeviceProp_t prop;
    CHECK(hipGetDeviceProperties(&prop, 0));

    const size_t n = (size_t)1 << 24;               // 16M floats = 64 MiB / array
    const size_t bytes = n * sizeof(float);

    float *da, *db, *dc;
    CHECK(hipMalloc(&da, bytes));
    CHECK(hipMalloc(&db, bytes));
    CHECK(hipMalloc(&dc, bytes));
    CHECK(hipMemset(da, 0x3f, bytes));              // 0.5f 左右，內容不重要
    CHECK(hipMemset(db, 0x3f, bytes));
    CHECK(hipMemset(dc, 0, bytes));

    int block = 256;
    int grid = (int)((n + block - 1) / block);

    for (int i = 0; i < warmup; i++)
        vector_add<<<grid, block>>>(da, db, dc, n);
    CHECK(hipGetLastError());
    CHECK(hipDeviceSynchronize());

    hipEvent_t e0, e1;
    CHECK(hipEventCreate(&e0));
    CHECK(hipEventCreate(&e1));

    std::vector<double> ms;
    ms.reserve(iters);
    for (int i = 0; i < iters; i++) {
        CHECK(hipEventRecord(e0));
        vector_add<<<grid, block>>>(da, db, dc, n);
        CHECK(hipGetLastError());
        CHECK(hipEventRecord(e1));
        CHECK(hipEventSynchronize(e1));
        float t = 0.0f;
        CHECK(hipEventElapsedTime(&t, e0, e1));
        ms.push_back((double)t);
    }

    double sum = 0.0;
    for (double t : ms) sum += t;
    double mn = *std::min_element(ms.begin(), ms.end());
    double md = median_of(ms);

    // 快速正確性檢查（避免量到壞掉的 kernel）
    float sample = 0.0f;
    CHECK(hipMemcpy(&sample, dc, sizeof(float), hipMemcpyDeviceToHost));

    printf("device     : %s (%s)\n", prop.name, prop.gcnArchName);
    printf("elements   : %zu (%.0f MiB per array, traffic %.0f MiB/iter)\n",
           n, bytes / 1048576.0, 3.0 * bytes / 1048576.0);
    printf("iters      : %d (warmup %d)\n", iters, warmup);
    printf("min_ms     : %.4f\n", mn);
    printf("median_ms  : %.4f\n", md);
    printf("mean_ms    : %.4f\n", sum / ms.size());
    printf("bw_min_gbs : %.1f\n", (3.0 * bytes) / (mn / 1000.0) / 1e9);
    printf("bw_med_gbs : %.1f\n", (3.0 * bytes) / (md / 1000.0) / 1e9);
    printf("sample     : %.3f (期望 1.0 左右)\n", sample);

    CHECK(hipFree(da)); CHECK(hipFree(db)); CHECK(hipFree(dc));
    return 0;
}
