#include "cuda/kernel.h"
#include <cstdio>
#include <assert.h>
#include <map>
#include <omp.h>
#include "gate.h"
#include "executor.h"
#include "dbg.h"
using namespace std;

static __shared__ cuCpx shm[1<<LOCAL_QUBIT_SIZE];
static __shared__ idx_t blockBias;

__device__ __constant__ value_t recRoot2 = 0.70710678118654752440084436210485; // more elegant way?
__constant__ KernelGate deviceGates[MAX_GATE];

std::vector<int*> loIdx_device;
std::vector<int*> shiftAt_device;


__device__ __forceinline__ void XSingle(int loIdx, int hiIdx) {
    cuCpx v = shm[loIdx];
    shm[loIdx] = shm[hiIdx];
    shm[hiIdx] = v;
}

__device__ __forceinline__ void YSingle(int loIdx, int hiIdx) {
    cuCpx lo = shm[loIdx];
    cuCpx hi = shm[hiIdx];
    
    shm[loIdx] = make_cuComplex(hi.y, -hi.x);
    shm[hiIdx] = make_cuComplex(-lo.y, lo.x);
}

__device__ __forceinline__ void ZHi(int hiIdx) {
    cuCpx v = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(-v.x, -v.y);
}


__device__ __forceinline__ void RXSingle(int loIdx, int hiIdx, value_t alpha, value_t beta) {
    cuCpx lo = shm[loIdx];
    cuCpx hi = shm[hiIdx];
    shm[loIdx] = make_cuComplex(alpha * lo.x + beta * hi.y, alpha * lo.y - beta * hi.x);
    shm[hiIdx] = make_cuComplex(alpha * hi.x + beta * lo.y, alpha * hi.y - beta * lo.x);
}

__device__ __forceinline__ void RYSingle(int loIdx, int hiIdx, value_t alpha, value_t beta) {
    cuCpx lo = shm[loIdx];
    cuCpx hi = shm[hiIdx];
    shm[loIdx] = make_cuComplex(alpha * lo.x - beta * hi.x, alpha * lo.y - beta * hi.y);
    shm[hiIdx] = make_cuComplex(beta * lo.x + alpha * hi.x, beta * lo.y + alpha * hi.y);
}

__device__ __forceinline__ void RZSingle(int loIdx, int hiIdx, value_t alpha, value_t beta){
    cuCpx lo = shm[loIdx];
    cuCpx hi = shm[hiIdx];
    shm[loIdx] = make_cuComplex(alpha * lo.x + beta * lo.y, alpha * lo.y - beta * lo.x);
    shm[hiIdx] = make_cuComplex(alpha * hi.x - beta * hi.y, alpha * hi.y + beta * hi.x);
}

__device__ __forceinline__ void RZLo(int loIdx, value_t alpha, value_t beta) {
    cuCpx lo = shm[loIdx];
    shm[loIdx] = make_cuComplex(alpha * lo.x + beta * lo.y, alpha * lo.y - beta * lo.x);
}

__device__ __forceinline__ void RZHi(int hiIdx, value_t alpha, value_t beta){
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(alpha * hi.x - beta * hi.y, alpha * hi.y + beta * hi.x);
}

#define COMPLEX_MULTIPLY_REAL(v0, v1) (v0.x * v1.x - v0.y * v1.y)
#define COMPLEX_MULTIPLY_IMAG(v0, v1) (v0.x * v1.y + v0.y * v1.x)

__device__ __forceinline__ void U1Hi(int hiIdx, cuCpx p) {
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(COMPLEX_MULTIPLY_REAL(hi, p), COMPLEX_MULTIPLY_IMAG(hi, p));
}

__device__ __forceinline__ void USingle(int loIdx, int hiIdx, cuCpx v00, cuCpx v01, cuCpx v10, cuCpx v11) {
    cuCpx lo = shm[loIdx];
    cuCpx hi = shm[hiIdx];
    shm[loIdx] = make_cuComplex(COMPLEX_MULTIPLY_REAL(lo, v00) + COMPLEX_MULTIPLY_REAL(hi, v01),
                               COMPLEX_MULTIPLY_IMAG(lo, v00) + COMPLEX_MULTIPLY_IMAG(hi, v01));
    shm[hiIdx] = make_cuComplex(COMPLEX_MULTIPLY_REAL(lo, v10) + COMPLEX_MULTIPLY_REAL(hi, v11),
                               COMPLEX_MULTIPLY_IMAG(lo, v10) + COMPLEX_MULTIPLY_IMAG(hi, v11));
}

__device__ __forceinline__ void HSingle(int loIdx, int hiIdx) {
    cuCpx lo = shm[loIdx];
    cuCpx hi = shm[hiIdx];
    shm[loIdx] = make_cuComplex(recRoot2 * (lo.x + hi.x), recRoot2 * (lo.y + hi.y));
    shm[hiIdx] = make_cuComplex(recRoot2 * (lo.x - hi.x), recRoot2 * (lo.y - hi.y));
}

__device__ __forceinline__ void SHi(int hiIdx) {
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(-hi.y, hi.x);
}

__device__ __forceinline__ void SDGHi(int hiIdx) {
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(hi.y, -hi.x);
}

__device__ __forceinline__ void THi(int hiIdx) {
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(recRoot2 * (hi.x - hi.y), recRoot2 * (hi.x + hi.y));
}

__device__ __forceinline__ void TDGHi(int hiIdx) {
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(recRoot2 * (hi.x + hi.y), recRoot2 * (hi.x - hi.y));
}
__device__ __forceinline__ void GIISingle(int loIdx, int hiIdx) {
    cuCpx lo = shm[loIdx];
    shm[loIdx] = make_cuComplex(-lo.y, lo.x);
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(-hi.y, hi.x);
}

__device__ __forceinline__ void GII(int idx) {
    cuCpx v = shm[idx];
    shm[idx] = make_cuComplex(-v.y, v.x);
}

__device__ __forceinline__ void GZZSingle(int loIdx, int hiIdx) {
    cuCpx lo = shm[loIdx];
    shm[loIdx] = make_cuComplex(-lo.x, -lo.y);
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(-hi.x, -hi.y);
}

__device__ __forceinline__ void GZZ(int idx) { 
    cuCpx v = shm[idx];
    shm[idx] = make_cuComplex(-v.x, -v.y);
}

__device__ __forceinline__ void GCCSingle(int loIdx, int hiIdx, cuCpx p) {
    cuCpx lo = shm[loIdx];
    shm[loIdx] = make_cuComplex(COMPLEX_MULTIPLY_REAL(lo, p), COMPLEX_MULTIPLY_IMAG(lo, p));
    cuCpx hi = shm[hiIdx];
    shm[hiIdx] = make_cuComplex(COMPLEX_MULTIPLY_REAL(hi, p), COMPLEX_MULTIPLY_IMAG(hi, p));
}

__device__ __forceinline__ void GCC(int idx, cuCpx p) {
    cuCpx v = shm[idx];
    shm[idx] = make_cuComplex(COMPLEX_MULTIPLY_REAL(v, p), COMPLEX_MULTIPLY_IMAG(v, p));
}

#define FOLLOW_NEXT(TYPE) \
case GateType::TYPE: // no break

#define CASE_CONTROL(TYPE, OP) \
case GateType::TYPE: { \
    assert(lo < 1024); \
    assert(hi < 1024); \
    OP; \
    lo += add; hi += add; \
    assert(lo < 1024); \
    assert(hi < 1024); \
    OP; \
    break; \
}

#define CASE_SINGLE(TYPE, OP) \
case GateType::TYPE: { \
    for (int task = 0; task < 4; task++) { \
        OP; \
        lo += add[task]; hi += add[task]; \
    } \
    break;\
}

#define CASE_LO_HI(TYPE, OP_LO, OP_HI) \
case GateType::TYPE: { \
    int m = 1 << LOCAL_QUBIT_SIZE; \
    if (!isHighBlock){ \
        for (int j = threadIdx.x; j < m; j += blockSize) { \
            OP_LO; \
        } \
    } else { \
        for (int j = threadIdx.x; j < m; j += blockSize) { \
            OP_HI; \
        } \
    } \
    break; \
}

#define CASE_SKIPLO_HI(TYPE, OP_HI) \
case GateType::TYPE: { \
    if (!isHighBlock) continue; \
    int m = 1 << LOCAL_QUBIT_SIZE; \
    for (int j = threadIdx.x; j < m; j += blockSize) { \
        OP_HI; \
    } \
    break; \
}

#define LOHI_SAME(TYPE, OP) \
case GateType::TYPE: { \
    int m = 1 << LOCAL_QUBIT_SIZE; \
    for (int j = threadIdx.x; j < m; j += blockSize) { \
        OP; \
    } \
    break; \
}

#define ID_BREAK() \
case GateType::ID: { \
    break; \
}

template <unsigned int blockSize>
__device__ void doCompute(int numGates, int* loArr, int* shiftAt) {
    for (int i = 0; i < numGates; i++) {
        int controlQubit = deviceGates[i].controlQubit;
        int targetQubit = deviceGates[i].targetQubit;
        char controlIsGlobal = deviceGates[i].controlIsGlobal;
        char targetIsGlobal = deviceGates[i].targetIsGlobal;
        if (deviceGates[i].type == GateType::CCX) {
            int encodeQubit = deviceGates[i].encodeQubit;
            int control2IsGlobal = deviceGates[i].control2IsGlobal;
            if (!control2IsGlobal) {
                int m = 1 << (LOCAL_QUBIT_SIZE - 1);
                assert(!controlIsGlobal && !targetIsGlobal);
                assert(deviceGates[i].type == GateType::CCX);
                int maskTarget = (1 << targetQubit) - 1;
                for (int j = threadIdx.x; j < m; j += blockSize) {
                    int lo = ((j >> targetQubit) << (targetQubit + 1)) | (j & maskTarget);
                    if (!(lo >> controlQubit & 1) || !(lo >> encodeQubit & 1))
                        continue;
                    int hi = lo | (1 << targetQubit);
                    lo ^= lo >> 3 & 7;
                    hi ^= hi >> 3 & 7;
                    XSingle(lo, hi);
                }
                continue;
            }
            if (control2IsGlobal == 1 && !((blockIdx.x >> encodeQubit) & 1)) {
                continue;
            }
        }
        if (!controlIsGlobal) {
            if (!targetIsGlobal) {
                int lo = loArr[(controlQubit * 10 + targetQubit) << THREAD_DEP | threadIdx.x];
                int hi = lo ^ (1 << targetQubit) ^ (((1 << targetQubit) >> 3) & 7);
                int add = 512;
                if (controlQubit == 9 || targetQubit == 9) {
                    add = 256;
                    if (controlQubit == 8 || targetQubit == 8)
                        add = 128;
                }
                switch (deviceGates[i].type) {
                    FOLLOW_NEXT(CCX)
                    CASE_CONTROL(CNOT, XSingle(lo, hi))
                    CASE_CONTROL(CY, YSingle(lo, hi))
                    CASE_CONTROL(CZ, ZHi(hi))
                    CASE_CONTROL(CRX, RXSingle(lo, hi, deviceGates[i].r00, -deviceGates[i].i01))
                    CASE_CONTROL(CRY, RYSingle(lo, hi, deviceGates[i].r00, deviceGates[i].r10))
                    CASE_CONTROL(CU1, U1Hi(hi, make_cuComplex(deviceGates[i].r11, deviceGates[i].i11)))
                    CASE_CONTROL(CRZ, RZSingle(lo, hi, deviceGates[i].r00, -deviceGates[i].i00))
                    CASE_CONTROL(CU, USingle(lo, hi, make_cuComplex(deviceGates[i].r00, deviceGates[i].i00), make_cuComplex(deviceGates[i].r01, deviceGates[i].i01), make_cuComplex(deviceGates[i].r10, deviceGates[i].i10), make_cuComplex(deviceGates[i].r11, deviceGates[i].i11)))
                    default: {
                        assert(false);
                    }
                }
            } else {
                assert(deviceGates[i].type == GateType::CZ || deviceGates[i].type == GateType::CU1 || deviceGates[i].type == GateType::CRZ);
                bool isHighBlock = (blockIdx.x >> targetQubit) & 1;
                int m = 1 << (LOCAL_QUBIT_SIZE - 1);
                int maskControl = (1 << controlQubit) - 1;
                if (!isHighBlock){
                    if (deviceGates[i].type == GateType::CRZ) {
                        for (int j = threadIdx.x; j < m; j += blockSize) {
                            int x = ((j >> controlQubit) << (controlQubit + 1)) | (j & maskControl)  | (1 << controlQubit);
                            x ^= x >> 3 & 7;
                            RZLo(x, deviceGates[i].r00, -deviceGates[i].i00);
                        }
                    }
                } else {
                    switch (deviceGates[i].type) {
                        case GateType::CZ: {
                            for (int j = threadIdx.x; j < m; j += blockSize) {
                                int x = ((j >> controlQubit) << (controlQubit + 1)) | (j & maskControl)  | (1 << controlQubit);
                                x ^= x >> 3 & 7;
                                ZHi(x);
                            }
                            break;    
                        }
                        case GateType::CU1: {
                            for (int j = threadIdx.x; j < m; j += blockSize) {
                                int x = ((j >> controlQubit) << (controlQubit + 1)) | (j & maskControl)  | (1 << controlQubit);
                                x ^= x >> 3 & 7;
                                U1Hi(x, make_cuComplex(deviceGates[i].r11, deviceGates[i].i11));
                            }
                            break;
                        }
                        case GateType::CRZ: {
                            for (int j = threadIdx.x; j < m; j += blockSize) {
                                int x = ((j >> controlQubit) << (controlQubit + 1)) | (j & maskControl)  | (1 << controlQubit);
                                x ^= x >> 3 & 7;
                                RZHi(x, deviceGates[i].r00, -deviceGates[i].i00);
                            }
                            break;
                        }
                        default: {
                            assert(false);
                        }
                    }
                }
            }
        } else {
            if (controlIsGlobal == 1 && !((blockIdx.x >> controlQubit) & 1)) {
                continue;
            }
            if (!targetIsGlobal) {
                int lo = loArr[(targetQubit * 11) << THREAD_DEP | threadIdx.x];
                int hi = lo ^ (1 << targetQubit) ^ (((1 << targetQubit) >> 3) & 7);
                int add[4];
                if (targetQubit < 8) {
                    add[0] = add[1] = add[2] = 256;
                } else if (targetQubit == 8) {
                    add[0] = 128; add[1] = 384; add[2] = 128;
                } else { // targetQubit == 9
                    add[0] = add[1] = add[2] = 128;
                }
                switch (deviceGates[i].type) {
                    FOLLOW_NEXT(GOC)
                    FOLLOW_NEXT(CU1)
                    CASE_SINGLE(U1, U1Hi(hi, make_cuComplex(deviceGates[i].r11, deviceGates[i].i11)))
                    FOLLOW_NEXT(U2)
                    FOLLOW_NEXT(U)
                    FOLLOW_NEXT(CU)
                    CASE_SINGLE(U3, USingle(lo, hi, make_cuComplex(deviceGates[i].r00, deviceGates[i].i00), make_cuComplex(deviceGates[i].r01, deviceGates[i].i01), make_cuComplex(deviceGates[i].r10, deviceGates[i].i10), make_cuComplex(deviceGates[i].r11, deviceGates[i].i11)));
                    CASE_SINGLE(H, HSingle(lo, hi))
                    FOLLOW_NEXT(X)
                    FOLLOW_NEXT(CNOT)
                    CASE_SINGLE(CCX, XSingle(lo, hi))
                    FOLLOW_NEXT(Y)
                    CASE_SINGLE(CY, YSingle(lo, hi))
                    FOLLOW_NEXT(Z)
                    CASE_SINGLE(CZ, ZHi(hi))
                    FOLLOW_NEXT(RX)
                    CASE_SINGLE(CRX, RXSingle(lo, hi, deviceGates[i].r00, -deviceGates[i].i01))
                    FOLLOW_NEXT(RY)
                    CASE_SINGLE(CRY, RYSingle(lo, hi, deviceGates[i].r00, deviceGates[i].r10))
                    FOLLOW_NEXT(RZ)
                    CASE_SINGLE(CRZ, RZSingle(lo, hi, deviceGates[i].r00, -deviceGates[i].i00))
                    CASE_SINGLE(S, SHi(hi))
                    CASE_SINGLE(SDG, SDGHi(hi))
                    CASE_SINGLE(T, THi(hi))
                    CASE_SINGLE(TDG, TDGHi(hi))
                    CASE_SINGLE(GII, GIISingle(lo, hi))
                    CASE_SINGLE(GZZ, GZZSingle(lo, hi))
                    CASE_SINGLE(GCC, GCCSingle(lo, hi, make_cuComplex(deviceGates[i].r00, deviceGates[i].i00)))
                    ID_BREAK()
                    default: {
                        assert(false);
                    }
                }
            } else {
                bool isHighBlock = (blockIdx.x >> targetQubit) & 1;
                switch (deviceGates[i].type) {
                    FOLLOW_NEXT(RZ)
                    CASE_LO_HI(CRZ, RZLo(j, deviceGates[i].r00, -deviceGates[i].i00), RZHi(j, deviceGates[i].r00, -deviceGates[i].i00))
                    FOLLOW_NEXT(Z)
                    CASE_SKIPLO_HI(CZ, ZHi(j))
                    CASE_SKIPLO_HI(S, SHi(j))
                    CASE_SKIPLO_HI(SDG, SDGHi(j))
                    CASE_SKIPLO_HI(T, THi(j))
                    CASE_SKIPLO_HI(TDG, TDGHi(j))
                    FOLLOW_NEXT(GOC)
                    FOLLOW_NEXT(CU1)
                    CASE_SKIPLO_HI(U1, U1Hi(j, make_cuComplex(deviceGates[i].r11, deviceGates[i].i11)))
                    LOHI_SAME(GII, GII(j))
                    LOHI_SAME(GZZ, GZZ(j))
                    LOHI_SAME(GCC, GCC(j, make_cuComplex(deviceGates[i].r00, deviceGates[i].i00)))
                    ID_BREAK()
                    default: {
                        assert(false);
                    }
                }
            }
        }
        __syncthreads();
    }
}

__device__ void fetchData(cuCpx* a, unsigned int* threadBias, unsigned int idx, unsigned int blockHot, unsigned int enumerate, int numLocalQubits) {
    if (threadIdx.x == 0) {
        int bid = blockIdx.x;
        unsigned int bias = 0;
        for (unsigned int bit = 1; bit < (1u << numLocalQubits); bit <<= 1) {
            if (blockHot & bit) {
                if (bid & 1)
                    bias |= bit;
                bid >>= 1;
            }
        }
        blockBias = bias;
    }
    __syncthreads();
    unsigned int bias = blockBias | threadBias[threadIdx.x];
    int x;
    unsigned int y;
    for (x = ((1 << (LOCAL_QUBIT_SIZE - THREAD_DEP)) - 1) << THREAD_DEP | threadIdx.x, y = enumerate;
        x >= 0;
        x -= (1 << THREAD_DEP), y = enumerate & (y - 1)) {
        
        shm[x ^ (x >> 3 & 7)] = a[bias | y];
    }
}

__device__ void saveData(cuCpx* a, unsigned int* threadBias, unsigned int enumerate) {
    unsigned int bias = blockBias | threadBias[threadIdx.x];
    int x;
    unsigned y;
    for (x = ((1 << (LOCAL_QUBIT_SIZE - THREAD_DEP)) - 1) << THREAD_DEP | threadIdx.x, y = enumerate;
        x >= 0;
        x -= (1 << THREAD_DEP), y = enumerate & (y - 1)) {
        
        a[bias | y] = shm[x ^ (x >> 3 & 7)];
    }
}

template <unsigned int blockSize>
__global__ void run(cuCpx* a, unsigned int* threadBias, int* loArr, int* shiftAt, int numLocalQubits, int numGates, unsigned int blockHot, unsigned int enumerate) {
    unsigned int idx = (unsigned int) blockIdx.x * blockSize + threadIdx.x;
    fetchData(a, threadBias, idx, blockHot, enumerate, numLocalQubits);
    __syncthreads();
    doCompute<blockSize>(numGates, loArr, shiftAt);
    __syncthreads();
    saveData(a, threadBias, enumerate);
}

#if GPU_BACKEND == 1 || GPU_BACKEND == 3 || GPU_BACKEND == 4 || GPU_BACKEND == 5
void initControlIdx() {
    int loIdx_host[10][10][128];
    int shiftAt_host[10][10];
    loIdx_device.resize(MyGlobalVars::localGPUs);
    shiftAt_device.resize(MyGlobalVars::localGPUs);
    for (int i = 0; i < MyGlobalVars::localGPUs; i++) {
        cudaSetDevice(i);
        cudaMalloc(&loIdx_device[i], sizeof(loIdx_host));
        cudaMalloc(&shiftAt_device[i], sizeof(shiftAt_host));
    }
    for (int i = 0; i < 128; i++)
        loIdx_host[0][0][i] = (i << 1) ^ ((i & 4) >> 2);

    for (int i = 0; i < 128; i++)
        loIdx_host[1][1][i] = (((i >> 4) << 5) | (i & 15)) ^ ((i & 2) << 3);

    for (int i = 0; i < 128; i++)
        loIdx_host[2][2][i] = (((i >> 5) << 6) | (i & 31)) ^ ((i & 4) << 3);
    
    for (int q = 3; q < 10; q++)
        for (int i = 0; i < 128; i++)
            loIdx_host[q][q][i] = ((i >> q) << (q + 1)) | (i & ((1 << q) - 1));

    for (int c = 0; c < 10; c++) {
        for (int t = 0; t < 10; t++) {
            if (c == t) continue;
            std::vector<int> a[8];
            for (int i = 0; i < 1024; i++) {
                int p = i ^ ((i >> 3) & 7);
                if ((p >> c & 1) && !(p >> t & 1)) {
                    a[i & 7].push_back(i);
                }
            }
            for (int i = 0; i < 8; i++) {
                if (a[i].size() == 0) {
                    for (int j = i + 1; j < 8; j++) {
                        if (a[j].size() == 64) {
                            std::vector<int> tmp = a[j];
                            a[j].clear();
                            for (int k = 0; k < 64; k += 2) {
                                a[i].push_back(tmp[k]);
                                a[j].push_back(tmp[k+1]);
                            }
                            break;
                        }
                    }
                }
            }
            for (int i = 0; i < 128; i++)
                loIdx_host[c][t][i] = a[i & 7][i / 8];
        }
    }

    loIdx_device.resize(MyGlobalVars::localGPUs);
    shiftAt_device.resize(MyGlobalVars::localGPUs);
    for (int g = 0; g < MyGlobalVars::localGPUs; g++) {
        checkCudaErrors(cudaMemcpyAsync(loIdx_device[g], loIdx_host[0][0], sizeof(loIdx_host), cudaMemcpyHostToDevice, MyGlobalVars::streams[g]));
        checkCudaErrors(cudaMemcpyAsync(shiftAt_device[g], shiftAt_host[0], sizeof(shiftAt_host), cudaMemcpyHostToDevice, MyGlobalVars::streams[g]));
    }
}
#endif

void copyGatesToSymbol(KernelGate* hostGates, int numGates, cudaStream_t& stream, int gpuID) {
    checkCudaErrors(cudaMemcpyToSymbolAsync(deviceGates, hostGates + gpuID * numGates, sizeof(KernelGate) * numGates, 0, cudaMemcpyDefault, stream));
}

void launchExecutor(int gridDim, cpx* deviceStateVec, unsigned int* threadBias, int numLocalQubits, int numGates, unsigned int blockHot, unsigned int enumerate, cudaStream_t& stream, int gpuID) {
    run<1<<THREAD_DEP><<<gridDim, 1<<THREAD_DEP, 0, stream>>>
        (reinterpret_cast<cuCpx*>(deviceStateVec), threadBias, loIdx_device[gpuID], shiftAt_device[gpuID], numLocalQubits, numGates, blockHot, enumerate);
}