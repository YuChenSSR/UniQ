#include "kernel.h"
#include <cstdio>
#include <assert.h>
using namespace std;

#define checkCudaErrors(err)  __checkCudaErrors (err, __FILE__, __LINE__)
inline void __checkCudaErrors(cudaError_t err, const char *file, const int line) {
    if (cudaSuccess != err)
    {
        fprintf(stderr, "checkCudaErrors() Driver API error = %04d \"%s\" from file <%s>, line %i.\n", err, cudaGetErrorString(err), file, line);
        exit(EXIT_FAILURE);
    }
}

const int SINGLE_SIZE_DEP = 0; // handle 1 << SINGLE_SIZE_DEP items per thread
const int THREAD_DEP = 7; // 1 << THREAD_DEP threads per block
const int REDUCE_BLOCK_DEP = 6; // 1 << REDUCE_BLOCK_DEP blocks in final reduction

void kernelInit(ComplexArray& deviceStateVec, int numQubits) {
    assert(numQubits > (SINGLE_SIZE_DEP +THREAD_DEP + 1 + REDUCE_BLOCK_DEP + THREAD_DEP + 1));
    assert(numQubits < 31);
    size_t size = sizeof(qreal) << numQubits;
    checkCudaErrors(cudaMalloc(&deviceStateVec.real, size));
    checkCudaErrors(cudaMalloc(&deviceStateVec.imag, size));
    checkCudaErrors(cudaMemset(deviceStateVec.real, 0, size));
    checkCudaErrors(cudaMemset(deviceStateVec.imag, 0, size));
    qreal one = 1;
    checkCudaErrors(cudaMemcpy(deviceStateVec.real, &one, sizeof(qreal), cudaMemcpyHostToDevice)); // state[0] = 1
}

template <unsigned int blockSize, GateType gate>
__global__ void controlledFixGate(ComplexArray a, int numQubit_, int controlQubit, int targetQubit) {
    qindex idx = blockIdx.x * blockSize + threadIdx.x;
    qindex mask = (qindex(1) << targetQubit) - 1;
    for (qindex i = (idx << SINGLE_SIZE_DEP); i < ((idx + 1) << SINGLE_SIZE_DEP); i++) {
        if (!((i >> controlQubit) & 1))
            continue;
        qindex lo = ((i >> targetQubit) << (targetQubit + 1)) | (i & mask);
        qindex hi = lo | (qindex(1) << targetQubit);
        if (gate == GateCNot) {
            qreal real = a.real[lo];
            qreal imag = a.imag[lo];
            a.real[lo] = a.real[hi];
            a.imag[lo] = a.imag[hi];
            a.real[hi] = real;
            a.imag[hi] = imag;
        }
    }
}


template <unsigned int blockSize, GateType gate>
__global__ void fixGate(ComplexArray a, int numQubit_, int targetQubit, qreal recRoot2) {
    qindex idx = blockIdx.x * blockSize + threadIdx.x;
    qindex mask = (qindex(1) << targetQubit) - 1;
    for (qindex i = (idx << SINGLE_SIZE_DEP); i < ((idx + 1) << SINGLE_SIZE_DEP); i++) {
        qindex lo = ((i >> targetQubit) << (targetQubit + 1)) | (i & mask);
        qindex hi = lo | (qindex(1) << targetQubit);
        if (gate == GateHadamard) {
            qreal loReal = a.real[lo];
            qreal loImag = a.imag[lo];
            qreal hiReal = a.real[hi];
            qreal hiImag = a.imag[hi];
            a.real[lo] = recRoot2 * (loReal + hiReal);
            a.imag[lo] = recRoot2 * (loImag + hiImag);
            a.real[hi] = recRoot2 * (loReal - hiReal);
            a.imag[hi] = recRoot2 * (loImag - hiImag);
        }
    }
}

template <unsigned int blockSize>
__global__ void controlAlphaBetaGate(ComplexArray a, int numQubit_, int controlQubit, int targetQubit, Complex alpha, Complex beta) {
    qindex idx = blockIdx.x * blockSize + threadIdx.x;
    qindex mask = (qindex(1) << targetQubit) - 1;
    for (qindex i = (idx << SINGLE_SIZE_DEP); i < ((idx + 1) << SINGLE_SIZE_DEP); i++) {
        if (!((i >> controlQubit) & 1))
            continue;
        qindex lo = ((i >> targetQubit) << (targetQubit + 1)) | (i & mask);
        qindex hi = lo | (qindex(1) << targetQubit);
        qreal loReal = a.real[lo];
        qreal loImag = a.imag[lo];
        qreal hiReal = a.real[hi];
        qreal hiImag = a.imag[hi];
        a.real[lo] = alpha.real * loReal - alpha.imag * loImag - beta.real * hiReal - beta.imag * hiImag;
        a.imag[lo] = alpha.real * loImag + alpha.imag * loReal - beta.real * hiImag + beta.imag * hiReal;
        a.real[hi] = beta.real * loReal - beta.imag * loImag + alpha.real * hiReal + alpha.imag * hiImag;
        a.imag[hi] = beta.real * loImag + beta.imag * loReal + alpha.real * hiImag - alpha.imag * hiReal;
    }
}


enum GateImpl {
    GateImplCFix,
    GateImplCAlphaBeta,
    GateImplFix,
    GateImplAlphaBeta
};

GateImpl toImpl(GateType type) {
    switch (type) {
        GateHadamard: return GateImplFix;
        GateCNot: return GateImplCFix;
        GateCPauliY: return GateImplCFix;
        GateCRotateX: return GateImplCAlphaBeta;
        GateCRotateY: return GateImplCAlphaBeta;
        GateCRotateZ: return GateImplCAlphaBeta;
        GatePauliX: return GateImplFix;
        GatePauliY: return GateImplFix;
        GatePauliZ: return GateImplFix;
        GateRotateX: return GateImplAlphaBeta;
        GateRotateY: return GateImplAlphaBeta;
        GateRotateZ: return GateImplAlphaBeta;
        GateS: return GateImplFix;
        GateT: return GateImplFix;
        default: assert(false);
    }
    // shouldn't reach here, just for compile
    return GateImplFix;
}

void kernelExec(ComplexArray& deviceStateVec, int numQubits, const vector<Gate>& gates) {
    int numQubit_ = numQubits - 1;
    int nVec = 1 << numQubit_;
    for (auto gate: gates) {
        switch (toImpl(gate.type)) {
            case GateImplCFix: {
                switch (gate.type) {
                    GateCNot: {
                        controlledFixGate<1<<THREAD_DEP, GateCNot><<<nVec>>(SINGLE_SIZE_DEP + THREAD_DEP), 1<<THREAD_DEP>>>(deviceStateVec, numQubit_, gate.controlQubit, gate.targetQubit);
                        break;
                    }
                    default: assert(false);
                }
                break;
            }
            case GateImplFix: {
                switch (gate.type) {
                    GateHadamard: {
                        fixGate<1<<THREAD_DEP, GateHadamard><<<nVec>>(SINGLE_SIZE_DEP + THREAD_DEP), 1<<THREAD_DEP>>>(deviceStateVec, numQubit_, gate.targetQubit, gate.mat[0][0].real);
                    }
                    default: assert(false);
                }
                break;
            }
            case GateImplCAlphaBeta: {
                controlAlphaBetaGate<1<<THREAD_DEP><<<nVec>>(SINGLE_SIZE_DEP + THREAD_DEP), 1<<THREAD_DEP>>>(
                    deviceStateVec, numQubit_, gate.controlQubit, gate.targetQubit, gate.mat[0][0], gate.mat[1][0]);
                break;
            }
            default: {
                assert(false);
            }
        }
    }
}

template <unsigned int blockSize>
__device__ void warpReduce(volatile qreal *sdata, unsigned int tid) {
    if (blockSize >= 64) sdata[tid] += sdata[tid + 32];
    if (blockSize >= 32) sdata[tid] += sdata[tid + 16];
    if (blockSize >= 16) sdata[tid] += sdata[tid + 8];
    if (blockSize >= 8) sdata[tid] += sdata[tid + 4];
    if (blockSize >= 4) sdata[tid] += sdata[tid + 2];
    if (blockSize >= 2) sdata[tid] += sdata[tid + 1];
}

template <unsigned int blockSize>
__device__ void blockReduce(volatile qreal *sdata, unsigned int tid) {
    if (blockSize >= 512) { if (tid < 256) { sdata[tid] += sdata[tid + 256]; } __syncthreads(); }
    if (blockSize >= 256) { if (tid < 128) { sdata[tid] += sdata[tid + 128]; } __syncthreads(); }
    if (blockSize >= 128) { if (tid < 64) { sdata[tid] += sdata[tid + 64]; } __syncthreads(); }
    if (tid < 32) warpReduce<blockSize>(sdata, tid);
}

template <unsigned int blockSize>
__global__ void reduce(qreal* g_idata, qreal *g_odata, unsigned int n, unsigned int gridSize) {
    __shared__ qreal sdata[blockSize];
    unsigned tid = threadIdx.x;
    unsigned idx = blockIdx.x * blockSize + threadIdx.x;
    unsigned twoGrid = gridSize << 1;
    sdata[tid] = 0;
    for (int i = idx; i < n; i += twoGrid) {
        sdata[tid] += g_idata[i] + g_idata[i + gridSize];
    }
    __syncthreads();
    blockReduce<blockSize>(sdata, tid);
    if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}

template <unsigned int blockSize>
__global__ void measure(ComplexArray a, qreal* ans, int numQubit_, int targetQubit) {
    __shared__ qreal sdata[blockSize];
    qindex idx = blockIdx.x * blockSize + threadIdx.x;
    int tid = threadIdx.x;
    qindex mask = (qindex(1) << targetQubit) - 1;
    sdata[tid] = 0;
    for (qindex i = (idx << SINGLE_SIZE_DEP); i < ((idx + 1) << SINGLE_SIZE_DEP); i++) {
        qindex lo = ((i >> targetQubit) << (targetQubit + 1)) | (i & mask);
        qreal loReal = a.real[lo];
        qreal loImag = a.imag[lo];
        sdata[tid] += loReal * loReal + loImag * loImag;
    }
    __syncthreads();
    blockReduce<blockSize>(sdata, tid);
    if (tid == 0) ans[blockIdx.x] = sdata[0];
}

qreal kernelMeasure(ComplexArray& deviceStateVec, int numQubits, int targetQubit) {
    int numQubit_ = numQubits - 1;
    qindex nVec = 1 << numQubit_;
    qindex totalBlocks = nVec >> THREAD_DEP >> SINGLE_SIZE_DEP;
    qreal *ans1, *ans2, *ans3;
    checkCudaErrors(cudaMalloc(&ans1, sizeof(qreal) * totalBlocks));
    measure<1<<THREAD_DEP><<<totalBlocks, 1<<THREAD_DEP>>>(deviceStateVec, ans1, numQubit_, targetQubit);
    checkCudaErrors(cudaMalloc(&ans2, sizeof(qreal) * (1<<REDUCE_BLOCK_DEP)));
    reduce<1<<THREAD_DEP><<<1<<REDUCE_BLOCK_DEP, 1<<THREAD_DEP>>>
        (ans1, ans2, totalBlocks, 1 << (THREAD_DEP + REDUCE_BLOCK_DEP));
    checkCudaErrors(cudaMallocHost(&ans3, sizeof(qreal) * (1<<REDUCE_BLOCK_DEP)));
    checkCudaErrors(cudaMemcpy(ans3, ans2, sizeof(qreal) * (1<<REDUCE_BLOCK_DEP), cudaMemcpyDeviceToHost));
    qreal ret = 0;
    for (int i = 0; i < (1<<REDUCE_BLOCK_DEP); i++)
        ret += ans3[i];
    checkCudaErrors(cudaFree(ans1));
    checkCudaErrors(cudaFree(ans2));
    checkCudaErrors(cudaFreeHost(ans3));
    return ret;
}

Complex kernelGetAmp(ComplexArray& deviceStateVec, qindex idx) {
    Complex ret;
    cudaMemcpy(&ret.real, deviceStateVec.real + idx, sizeof(qreal), cudaMemcpyDeviceToHost);
    cudaMemcpy(&ret.imag, deviceStateVec.imag + idx, sizeof(qreal), cudaMemcpyDeviceToHost);
    return ret;
}