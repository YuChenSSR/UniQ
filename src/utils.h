#pragma once

#include <cstdio>
#include <cuComplex.h>

typedef float qreal;
typedef int qindex;
typedef cuFloatComplex qComplex;
#define make_qComplex make_cuFloatComplex

const int LOCAL_QUBIT_SIZE = 10; // is hardcoded

struct Complex {
    qreal real;
    qreal imag;

    Complex() = default;
    Complex(qreal x): real(x), imag(0) {}
    Complex(qreal real, qreal imag): real(real), imag(imag) {}
    Complex(const Complex&) = default;
    Complex(const qComplex& x): real(x.x), imag(x.y) {}
    Complex& operator = (qreal x) {
        real = x;
        imag = 0;
        return *this;
    }
    qreal len() const { return real * real + imag * imag; }
};

struct ComplexArray {
    qreal *real;
    qreal *imag;
};

template<typename T>
int bitCount(T x) {
    int ret = 0;
    for (T i = x; i; i -= i & (-i)) {
        ret++;
    }
    return ret;
}