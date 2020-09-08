// Copyright (c) 2019-2020, NVIDIA CORPORATION.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <cooperative_groups.h>

#if ( __CUDACC_VER_MAJOR__ > 10 )
#include <cooperative_groups/reduce.h>
#endif

namespace cg = cooperative_groups;

// Check if C++17 is being used
#if __cplusplus >= 201703L
#include <thrust/complex.h>
///////////////////////////////////////////////////////////////////////////////
//                          CHANNELIZER 8x8                                  //
///////////////////////////////////////////////////////////////////////////////

// T is input type
// U is output type
template<typename T, typename U, int M = 8, int WARPSIZE = 32>
__device__ void _cupy_channelizer_8x8( const int n_chans,
                                       const int n_taps,
                                       const int n_pts,
                                       const T *__restrict__ x,
                                       const T *__restrict__ h,
                                       U *__restrict__ y,
                                       T s_h[M][M],
                                       T s_reg[M][M] ) {

    const auto block { cg::this_thread_block( ) };
    const auto tile_32 { cg::tiled_partition<WARPSIZE>( block ) };
    const auto tile { cg::tiled_partition<M>( tile_32 ) };

    const auto btx { blockIdx.x * blockDim.x + threadIdx.x };

    const auto tx { threadIdx.x };
    const auto ty { threadIdx.y };

    // Initialize shared memory
    // Evaluate type at compile-time
    if ( btx < n_chans && ty < n_taps ) {
        if constexpr ( std::is_same_v<T, thrust::complex<float>> || std::is_same_v<T, thrust::complex<double>> ) {
            s_h[tx][ty] = thrust::conj( h[ty * n_chans + btx] );
        } else {
            s_h[tx][ty] = h[ty * n_chans + btx];
        }
    } else {
        if constexpr ( std::is_same_v<T, thrust::complex<float>> || std::is_same_v<T, thrust::complex<double>> ) {
            s_h[tx][ty] = T( 0, 0 );
        } else {
            s_h[tx][ty] = 0.0;
        }
    }

    for ( auto bid = blockIdx.y; bid < n_pts; bid += blockDim.y ) {
        // Load data
        if ( bid >= n_taps ) {
            if ( btx < n_chans && ty < n_taps ) {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][( n_taps - 1 ) - ty] =
                        thrust::conj( x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )] );
                } else {
                    s_reg[tx][( n_taps - 1 ) - ty] = x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )];
                }
            }
        } else {
            if ( btx < n_chans && ty <= bid ) {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][bid - ty] = thrust::conj( x[ty * n_chans + ( n_chans - 1 - btx )] );
                } else {
                    s_reg[tx][bid - ty] = x[ty * n_chans + ( n_chans - 1 - btx )];
                }
            } else {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][ty] = T( 0, 0 );
                } else {
                    s_reg[tx][ty] = 0.0;
                }
            }
        }

        __syncthreads( );

        U temp {};
        U vv {};

        // Perform compute
        if ( ( blockIdx.x * M + ty ) < n_chans ) {
            temp = s_h[ty][tx] * s_reg[ty][tx];
            vv.real( cg::reduce( tile, temp.real( ), cg::plus<typename U::value_type>( ) ) );
            vv.imag( cg::reduce( tile, temp.imag( ), cg::plus<typename U::value_type>( ) ) );
        }

        // Store output
        if ( tx == 0 && ( blockIdx.x * M + ty ) < n_chans ) {
            y[bid * n_chans + ( blockIdx.x * M + ty )] = vv;
        }
    }
}

extern "C" __global__ void __launch_bounds__( 64 )
    _cupy_channelizer_8x8_float32_complex64( const int n_chans,
                                             const int n_taps,
                                             const int n_pts,
                                             const float *__restrict__ x,
                                             const float *__restrict__ h,
                                             thrust::complex<float> *__restrict__ y ) {

    __shared__ float s_h[8][8];
    __shared__ float s_reg[8][8];

    _cupy_channelizer_8x8<float, thrust::complex<float>>( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 64 )
    _cupy_channelizer_8x8_complex64_complex64( const int n_chans,
                                               const int n_taps,
                                               const int n_pts,
                                               const thrust::complex<float> *__restrict__ x,
                                               const thrust::complex<float> *__restrict__ h,
                                               thrust::complex<float> *__restrict__ y ) {

    __shared__ thrust::complex<float> s_h[8][8];
    __shared__ thrust::complex<float> s_reg[8][8];

    _cupy_channelizer_8x8<thrust::complex<float>, thrust::complex<float>>(
        n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 64 )
    _cupy_channelizer_8x8_float64_complex128( const int n_chans,
                                              const int n_taps,
                                              const int n_pts,
                                              const double *__restrict__ x,
                                              const double *__restrict__ h,
                                              thrust::complex<double> *__restrict__ y ) {

    __shared__ double s_h[8][8];
    __shared__ double s_reg[8][8];

    _cupy_channelizer_8x8<double, thrust::complex<double>>( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 64 )
    _cupy_channelizer_8x8_complex128_complex128( const int n_chans,
                                                 const int n_taps,
                                                 const int n_pts,
                                                 const thrust::complex<double> *__restrict__ x,
                                                 const thrust::complex<double> *__restrict__ h,
                                                 thrust::complex<double> *__restrict__ y ) {

    __shared__ thrust::complex<double> s_h[8][8];
    __shared__ thrust::complex<double> s_reg[8][8];

    _cupy_channelizer_8x8<thrust::complex<double>, thrust::complex<double>>(
        n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

///////////////////////////////////////////////////////////////////////////////
//                        CHANNELIZER 16x16                                  //
///////////////////////////////////////////////////////////////////////////////

// T is input type
// U is output type
template<typename T, typename U, int M = 16, int WARPSIZE = 32>
__device__ void _cupy_channelizer_16x16( const int n_chans,
                                         const int n_taps,
                                         const int n_pts,
                                         const T *__restrict__ x,
                                         const T *__restrict__ h,
                                         U *__restrict__ y,
                                         T s_h[M][M],
                                         T s_reg[M][M] ) {

    const auto block { cg::this_thread_block( ) };
    const auto tile_32 { cg::tiled_partition<WARPSIZE>( block ) };
    const auto tile { cg::tiled_partition<M>( tile_32 ) };

    const auto btx { blockIdx.x * blockDim.x + threadIdx.x };

    const auto tx { threadIdx.x };
    const auto ty { threadIdx.y };

    // Initialize shared memory
    // Evaluate type at compile-time
    if ( btx < n_chans && ty < n_taps ) {
        if constexpr ( std::is_same_v<T, thrust::complex<float>> || std::is_same_v<T, thrust::complex<double>> ) {
            s_h[tx][ty] = thrust::conj( h[ty * n_chans + btx] );
        } else {
            s_h[tx][ty] = h[ty * n_chans + btx];
        }
    } else {
        if constexpr ( std::is_same_v<T, thrust::complex<float>> || std::is_same_v<T, thrust::complex<double>> ) {
            s_h[tx][ty] = T( 0, 0 );
        } else {
            s_h[tx][ty] = 0.0;
        }
    }

    for ( auto bid = blockIdx.y; bid < n_pts; bid += blockDim.y ) {
        // Load data
        if ( bid >= n_taps ) {
            if ( btx < n_chans && ty < n_taps ) {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][( n_taps - 1 ) - ty] =
                        thrust::conj( x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )] );
                } else {
                    s_reg[tx][( n_taps - 1 ) - ty] = x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )];
                }
            }
        } else {
            if ( btx < n_chans && ty <= bid ) {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][bid - ty] = thrust::conj( x[ty * n_chans + ( n_chans - 1 - btx )] );
                } else {
                    s_reg[tx][bid - ty] = x[ty * n_chans + ( n_chans - 1 - btx )];
                }
            } else {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][ty] = T( 0, 0 );
                } else {
                    s_reg[tx][ty] = 0.0;
                }
            }
        }

        __syncthreads( );

        U temp {};
        U vv {};

        // Perform compute
        if ( ( blockIdx.x * M + ty ) < n_chans ) {
            temp = s_h[ty][tx] * s_reg[ty][tx];
            vv.real( cg::reduce( tile, temp.real( ), cg::plus<typename U::value_type>( ) ) );
            vv.imag( cg::reduce( tile, temp.imag( ), cg::plus<typename U::value_type>( ) ) );
        }

        // Store output
        if ( tx == 0 && ( blockIdx.x * M + ty ) < n_chans ) {
            y[bid * n_chans + ( blockIdx.x * M + ty )] = vv;
        }
    }
}

extern "C" __global__ void __launch_bounds__( 256 )
    _cupy_channelizer_16x16_float32_complex64( const int n_chans,
                                               const int n_taps,
                                               const int n_pts,
                                               const float *__restrict__ x,
                                               const float *__restrict__ h,
                                               thrust::complex<float> *__restrict__ y ) {

    __shared__ float s_h[16][16];
    __shared__ float s_reg[16][16];

    _cupy_channelizer_16x16<float, thrust::complex<float>>( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 256 )
    _cupy_channelizer_16x16_complex64_complex64( const int n_chans,
                                                 const int n_taps,
                                                 const int n_pts,
                                                 const thrust::complex<float> *__restrict__ x,
                                                 const thrust::complex<float> *__restrict__ h,
                                                 thrust::complex<float> *__restrict__ y ) {

    __shared__ thrust::complex<float> s_h[16][16];
    __shared__ thrust::complex<float> s_reg[16][16];

    _cupy_channelizer_16x16<thrust::complex<float>, thrust::complex<float>>(
        n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 256 )
    _cupy_channelizer_16x16_float64_complex128( const int n_chans,
                                                const int n_taps,
                                                const int n_pts,
                                                const double *__restrict__ x,
                                                const double *__restrict__ h,
                                                thrust::complex<double> *__restrict__ y ) {

    __shared__ double s_h[16][16];
    __shared__ double s_reg[16][16];

    _cupy_channelizer_16x16<double, thrust::complex<double>>( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 256 )
    _cupy_channelizer_16x16_complex128_complex128( const int n_chans,
                                                   const int n_taps,
                                                   const int n_pts,
                                                   const thrust::complex<double> *__restrict__ x,
                                                   const thrust::complex<double> *__restrict__ h,
                                                   thrust::complex<double> *__restrict__ y ) {

    __shared__ thrust::complex<double> s_h[16][16];
    __shared__ thrust::complex<double> s_reg[16][16];

    _cupy_channelizer_16x16<thrust::complex<double>, thrust::complex<double>>(
        n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

///////////////////////////////////////////////////////////////////////////////
//                        CHANNELIZER 32x32                                  //
///////////////////////////////////////////////////////////////////////////////

// T is input type
// U is output type
template<typename T, typename U, int M = 32, int WARPSIZE = 32>
__device__ void _cupy_channelizer_32x32( const int n_chans,
                                         const int n_taps,
                                         const int n_pts,
                                         const T *__restrict__ x,
                                         const T *__restrict__ h,
                                         U *__restrict__ y,
                                         T s_h[M][M],
                                         T s_reg[M][M] ) {

    const auto block { cg::this_thread_block( ) };
    const auto tile { cg::tiled_partition<WARPSIZE>( block ) };

    const auto btx { blockIdx.x * blockDim.x + threadIdx.x };

    const auto tx { threadIdx.x };
    const auto ty { threadIdx.y };

    // Initialize shared memory
    // Evaluate type at compile-time
    if ( btx < n_chans && ty < n_taps ) {
        if constexpr ( std::is_same_v<T, thrust::complex<float>> || std::is_same_v<T, thrust::complex<double>> ) {
            s_h[tx][ty] = thrust::conj( h[ty * n_chans + btx] );
        } else {
            s_h[tx][ty] = h[ty * n_chans + btx];
        }
    } else {
        if constexpr ( std::is_same_v<T, thrust::complex<float>> || std::is_same_v<T, thrust::complex<double>> ) {
            s_h[tx][ty] = T( 0, 0 );
        } else {
            s_h[tx][ty] = 0.0;
        }
    }

    for ( auto bid = blockIdx.y; bid < n_pts; bid += blockDim.y ) {
        // Load data
        if ( bid >= n_taps ) {
            if ( btx < n_chans && ty < n_taps ) {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][( n_taps - 1 ) - ty] =
                        thrust::conj( x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )] );
                } else {
                    s_reg[tx][( n_taps - 1 ) - ty] = x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )];
                }
            }
        } else {
            if ( btx < n_chans && ty <= bid ) {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][bid - ty] = thrust::conj( x[ty * n_chans + ( n_chans - 1 - btx )] );
                } else {
                    s_reg[tx][bid - ty] = x[ty * n_chans + ( n_chans - 1 - btx )];
                }
            } else {
                if constexpr ( std::is_same_v<T, thrust::complex<float>> ||
                               std::is_same_v<T, thrust::complex<double>> ) {
                    s_reg[tx][ty] = T( 0, 0 );
                } else {
                    s_reg[tx][ty] = 0.0;
                }
            }
        }

        __syncthreads( );

        U temp {};
        U vv {};

        // Perform compute
        if ( ( blockIdx.x * M + ty ) < n_chans ) {
            temp = s_h[ty][tx] * s_reg[ty][tx];
            vv.real( cg::reduce( tile, temp.real( ), cg::plus<typename U::value_type>( ) ) );
            vv.imag( cg::reduce( tile, temp.imag( ), cg::plus<typename U::value_type>( ) ) );
        }

        // Store output
        if ( tx == 0 && ( blockIdx.x * M + ty ) < n_chans ) {
            y[bid * n_chans + ( blockIdx.x * M + ty )] = vv;
        }
    }
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_32x32_float32_complex64( const int n_chans,
                                               const int n_taps,
                                               const int n_pts,
                                               const float *__restrict__ x,
                                               const float *__restrict__ h,
                                               thrust::complex<float> *__restrict__ y ) {

    __shared__ float s_h[32][32];
    __shared__ float s_reg[32][32];

    _cupy_channelizer_32x32<float, thrust::complex<float>>( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_32x32_complex64_complex64( const int n_chans,
                                                 const int n_taps,
                                                 const int n_pts,
                                                 const thrust::complex<float> *__restrict__ x,
                                                 const thrust::complex<float> *__restrict__ h,
                                                 thrust::complex<float> *__restrict__ y ) {

    __shared__ thrust::complex<float> s_h[32][32];
    __shared__ thrust::complex<float> s_reg[32][32];

    _cupy_channelizer_32x32<thrust::complex<float>, thrust::complex<float>>(
        n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_32x32_float64_complex128( const int n_chans,
                                                const int n_taps,
                                                const int n_pts,
                                                const double *__restrict__ x,
                                                const double *__restrict__ h,
                                                thrust::complex<double> *__restrict__ y ) {

    __shared__ double s_h[32][32];
    __shared__ double s_reg[32][32];

    _cupy_channelizer_32x32<double, thrust::complex<double>>( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_32x32_complex128_complex128( const int n_chans,
                                                   const int n_taps,
                                                   const int n_pts,
                                                   const thrust::complex<double> *__restrict__ x,
                                                   const thrust::complex<double> *__restrict__ h,
                                                   thrust::complex<double> *__restrict__ y ) {

    __shared__ thrust::complex<double> s_h[32][32];
    __shared__ thrust::complex<double> s_reg[32][32];

    _cupy_channelizer_32x32<thrust::complex<double>, thrust::complex<double>>(
        n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}
#else  // C++11 being used
#include <cuComplex.h>

template<typename T, int tile_sz>
__device__ T reduce_sum_tile_shfl( cg::thread_block_tile<tile_sz> g, T val ) {
    // Each iteration halves the number of active threads
    // Each thread adds its partial sum[i] to sum[lane+i]
    for ( int i = g.size( ) / 2; i > 0; i /= 2 ) {
        val += g.shfl_down( val, i );
    }

    return val;  // note: only thread 0 will return full sum
}

///////////////////////////////////////////////////////////////////////////////
//                        CHANNELIZER F/CF                                   //
///////////////////////////////////////////////////////////////////////////////

template<int M = 32, int WARPSIZE = 32>
__device__ void _cupy_channelizer_32x32_float32_complex64( const int n_chans,
                                                           const int n_taps,
                                                           const int n_pts,
                                                           const float *__restrict__ x,
                                                           const float *__restrict__ h,
                                                           cuFloatComplex *__restrict__ y,
                                                           float s_h[M][M],
                                                           float s_reg[M][M] ) {

    const auto block = cg::this_thread_block( );
    const auto tile  = cg::tiled_partition<WARPSIZE>( block );

    const unsigned int btx { blockIdx.x * blockDim.x + threadIdx.x };

    const unsigned int tx { threadIdx.x };
    const unsigned int ty { threadIdx.y };

    // Initialize shared memory
    // Evaluate type at compile-time
    if ( btx < n_chans && ty < n_taps ) {
        s_h[tx][ty] = h[ty * n_chans + btx];
    } else {
        s_h[tx][ty] = 0.0f;
    }

    for ( auto bid = blockIdx.y; bid < n_pts; bid += blockDim.y ) {
        // Load data
        if ( bid >= n_taps ) {
            if ( btx < n_chans && ty < n_taps ) {
                s_reg[tx][( n_taps - 1 ) - ty] = x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )];
            }
        } else {
            if ( btx < n_chans && ty <= bid ) {
                s_reg[tx][bid - ty] = x[ty * n_chans + ( n_chans - 1 - btx )];
            } else {

                s_reg[tx][ty] = 0.0f;
            }
        }

        __syncthreads( );

        cuFloatComplex temp {};
        cuFloatComplex vv {};

        // Perform compute
        if ( ( blockIdx.x * M + ty ) < n_chans ) {
            temp.x = s_h[ty][tx] * s_reg[ty][tx];
            vv.x   = reduce_sum_tile_shfl<float, WARPSIZE>( tile, temp.x );
        }

        // Store output
        if ( tx == 0 && ( blockIdx.x * M + ty ) < n_chans ) {
            y[bid * n_chans + ( blockIdx.x * M + ty )] = vv;
        }
    }
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_8x8_float32_complex64( const int n_chans,
                                             const int n_taps,
                                             const int n_pts,
                                             const float *__restrict__ x,
                                             const float *__restrict__ h,
                                             cuFloatComplex *__restrict__ y ) {

    __shared__ float s_h[32][32];
    __shared__ float s_reg[32][32];

    _cupy_channelizer_32x32_float32_complex64( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_16x16_float32_complex64( const int n_chans,
                                               const int n_taps,
                                               const int n_pts,
                                               const float *__restrict__ x,
                                               const float *__restrict__ h,
                                               cuFloatComplex *__restrict__ y ) {

    __shared__ float s_h[32][32];
    __shared__ float s_reg[32][32];

    _cupy_channelizer_32x32_float32_complex64( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_32x32_float32_complex64( const int n_chans,
                                               const int n_taps,
                                               const int n_pts,
                                               const float *__restrict__ x,
                                               const float *__restrict__ h,
                                               cuFloatComplex *__restrict__ y ) {

    __shared__ float s_h[32][32];
    __shared__ float s_reg[32][32];

    _cupy_channelizer_32x32_float32_complex64( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

///////////////////////////////////////////////////////////////////////////////
//                        CHANNELIZER CF/CF                                  //
///////////////////////////////////////////////////////////////////////////////

template<int M = 32, int WARPSIZE = 32>
__device__ void _cupy_channelizer_32x32_complex64_complex64( const int n_chans,
                                                             const int n_taps,
                                                             const int n_pts,
                                                             const cuFloatComplex *__restrict__ x,
                                                             const cuFloatComplex *__restrict__ h,
                                                             cuFloatComplex *__restrict__ y,
                                                             cuFloatComplex s_h[M][M],
                                                             cuFloatComplex s_reg[M][M] ) {

    const auto block = cg::this_thread_block( );
    const auto tile  = cg::tiled_partition<WARPSIZE>( block );

    const unsigned int btx { blockIdx.x * blockDim.x + threadIdx.x };

    const unsigned int tx { threadIdx.x };
    const unsigned int ty { threadIdx.y };

    // Initialize shared memory
    // Evaluate type at compile-time
    if ( btx < n_chans && ty < n_taps ) {
        s_h[tx][ty] = h[ty * n_chans + btx];
    } else {
        s_h[tx][ty].x = 0.0f;
        s_h[tx][ty].y = 0.0f;
    }

    for ( auto bid = blockIdx.y; bid < n_pts; bid += blockDim.y ) {
        // Load data
        if ( bid >= n_taps ) {
            if ( btx < n_chans && ty < n_taps ) {
                s_reg[tx][( n_taps - 1 ) - ty] = x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )];
            }
        } else {
            if ( btx < n_chans && ty <= bid ) {
                s_reg[tx][bid - ty] = x[ty * n_chans + ( n_chans - 1 - btx )];
            } else {
                s_reg[tx][ty].x = 0.0f;
                s_reg[tx][ty].y = 0.0f;
            }
        }

        __syncthreads( );

        cuFloatComplex temp {};
        cuFloatComplex vv {};

        // Perform compute
        if ( ( blockIdx.x * M + ty ) < n_chans ) {
            temp = cuCmulf( s_h[ty][tx], s_reg[ty][tx] );
            vv.x = reduce_sum_tile_shfl<float, WARPSIZE>( tile, temp.x );
            vv.y = reduce_sum_tile_shfl<float, WARPSIZE>( tile, temp.y );
        }

        // Store output
        if ( tx == 0 && ( blockIdx.x * M + ty ) < n_chans ) {
            y[bid * n_chans + ( blockIdx.x * M + ty )] = vv;
        }
    }
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_8x8_complex64_complex64( const int n_chans,
                                               const int n_taps,
                                               const int n_pts,
                                               const cuFloatComplex *__restrict__ x,
                                               const cuFloatComplex *__restrict__ h,
                                               cuFloatComplex *__restrict__ y ) {

    __shared__ cuFloatComplex s_h[32][32];
    __shared__ cuFloatComplex s_reg[32][32];

    _cupy_channelizer_32x32_complex64_complex64( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_16x16_complex64_complex64( const int n_chans,
                                                 const int n_taps,
                                                 const int n_pts,
                                                 const cuFloatComplex *__restrict__ x,
                                                 const cuFloatComplex *__restrict__ h,
                                                 cuFloatComplex *__restrict__ y ) {

    __shared__ cuFloatComplex s_h[32][32];
    __shared__ cuFloatComplex s_reg[32][32];

    _cupy_channelizer_32x32_complex64_complex64( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_32x32_complex64_complex64( const int n_chans,
                                                 const int n_taps,
                                                 const int n_pts,
                                                 const cuFloatComplex *__restrict__ x,
                                                 const cuFloatComplex *__restrict__ h,
                                                 cuFloatComplex *__restrict__ y ) {

    __shared__ cuFloatComplex s_h[32][32];
    __shared__ cuFloatComplex s_reg[32][32];

    _cupy_channelizer_32x32_complex64_complex64( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

///////////////////////////////////////////////////////////////////////////////
//                        CHANNELIZER D/CD                                   //
///////////////////////////////////////////////////////////////////////////////

template<int M = 32, int WARPSIZE = 32>
__device__ void _cupy_channelizer_32x32_float64_complex128( const int n_chans,
                                                            const int n_taps,
                                                            const int n_pts,
                                                            const double *__restrict__ x,
                                                            const double *__restrict__ h,
                                                            cuDoubleComplex *__restrict__ y,
                                                            double s_h[M][M],
                                                            double s_reg[M][M] ) {

    const auto block = cg::this_thread_block( );
    const auto tile  = cg::tiled_partition<WARPSIZE>( block );

    const unsigned int btx { blockIdx.x * blockDim.x + threadIdx.x };

    const unsigned int tx { threadIdx.x };
    const unsigned int ty { threadIdx.y };

    // Initialize shared memory
    // Evaluate type at compile-time
    if ( btx < n_chans && ty < n_taps ) {
        s_h[tx][ty] = h[ty * n_chans + btx];
    } else {
        s_h[tx][ty] = 0.0f;
    }

    for ( auto bid = blockIdx.y; bid < n_pts; bid += blockDim.y ) {
        // Load data
        if ( bid >= n_taps ) {
            if ( btx < n_chans && ty < n_taps ) {
                s_reg[tx][( n_taps - 1 ) - ty] = x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )];
            }
        } else {
            if ( btx < n_chans && ty <= bid ) {
                s_reg[tx][bid - ty] = x[ty * n_chans + ( n_chans - 1 - btx )];
            } else {
                s_reg[tx][ty] = 0.0f;
            }
        }

        __syncthreads( );

        cuDoubleComplex temp {};
        cuDoubleComplex vv {};

        // Perform compute
        if ( ( blockIdx.x * M + ty ) < n_chans ) {
            temp.x = s_h[ty][tx] * s_reg[ty][tx];
            vv.x   = reduce_sum_tile_shfl<double, WARPSIZE>( tile, temp.x );
        }

        // Store output
        if ( tx == 0 && ( blockIdx.x * M + ty ) < n_chans ) {
            y[bid * n_chans + ( blockIdx.x * M + ty )] = vv;
        }
    }
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_8x8_float64_complex128( const int n_chans,
                                              const int n_taps,
                                              const int n_pts,
                                              const double *__restrict__ x,
                                              const double *__restrict__ h,
                                              cuDoubleComplex *__restrict__ y ) {

    __shared__ double s_h[32][32];
    __shared__ double s_reg[32][32];

    _cupy_channelizer_32x32_float64_complex128( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_16x16_float64_complex128( const int n_chans,
                                                const int n_taps,
                                                const int n_pts,
                                                const double *__restrict__ x,
                                                const double *__restrict__ h,
                                                cuDoubleComplex *__restrict__ y ) {

    __shared__ double s_h[32][32];
    __shared__ double s_reg[32][32];

    _cupy_channelizer_32x32_float64_complex128( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_32x32_float64_complex128( const int n_chans,
                                                const int n_taps,
                                                const int n_pts,
                                                const double *__restrict__ x,
                                                const double *__restrict__ h,
                                                cuDoubleComplex *__restrict__ y ) {

    __shared__ double s_h[32][32];
    __shared__ double s_reg[32][32];

    _cupy_channelizer_32x32_float64_complex128( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

///////////////////////////////////////////////////////////////////////////////
//                        CHANNELIZER CD/CD                                  //
///////////////////////////////////////////////////////////////////////////////

template<int M = 32, int WARPSIZE = 32>
__device__ void _cupy_channelizer_32x32_complex128_complex128( const int n_chans,
                                                               const int n_taps,
                                                               const int n_pts,
                                                               const cuDoubleComplex *__restrict__ x,
                                                               const cuDoubleComplex *__restrict__ h,
                                                               cuDoubleComplex *__restrict__ y,
                                                               cuDoubleComplex s_h[M][M],
                                                               cuDoubleComplex s_reg[M][M] ) {

    const auto block = cg::this_thread_block( );
    const auto tile  = cg::tiled_partition<WARPSIZE>( block );

    const unsigned int btx { blockIdx.x * blockDim.x + threadIdx.x };

    const unsigned int tx { threadIdx.x };
    const unsigned int ty { threadIdx.y };

    // Initialize shared memory
    // Evaluate type at compile-time
    if ( btx < n_chans && ty < n_taps ) {
        s_h[tx][ty] = h[ty * n_chans + btx];
    } else {
        s_h[tx][ty].x = 0.0;
        s_h[tx][ty].y = 0.0;
    }

    for ( auto bid = blockIdx.y; bid < n_pts; bid += blockDim.y ) {
        // Load data
        if ( bid >= n_taps ) {
            if ( btx < n_chans && ty < n_taps ) {
                s_reg[tx][( n_taps - 1 ) - ty] = x[( ( bid - n_taps + 1 ) + ty ) * n_chans + ( n_chans - 1 - btx )];
            }
        } else {
            if ( btx < n_chans && ty <= bid ) {
                s_reg[tx][bid - ty] = x[ty * n_chans + ( n_chans - 1 - btx )];
            } else {

                s_reg[tx][ty].x = 0.0;
                s_reg[tx][ty].y = 0.0;
            }
        }

        __syncthreads( );

        cuDoubleComplex temp {};
        cuDoubleComplex vv {};

        // Perform compute
        if ( ( blockIdx.x * M + ty ) < n_chans ) {
            temp = cuCmul( s_h[ty][tx], s_reg[ty][tx] );
            vv.x = reduce_sum_tile_shfl<double, WARPSIZE>( tile, temp.x );
            vv.y = reduce_sum_tile_shfl<double, WARPSIZE>( tile, temp.y );
        }

        // Store output
        if ( tx == 0 && ( blockIdx.x * M + ty ) < n_chans ) {
            y[bid * n_chans + ( blockIdx.x * M + ty )] = vv;
        }
    }
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_8x8_complex128_complex128( const int n_chans,
                                                 const int n_taps,
                                                 const int n_pts,
                                                 const cuDoubleComplex *__restrict__ x,
                                                 const cuDoubleComplex *__restrict__ h,
                                                 cuDoubleComplex *__restrict__ y ) {

    __shared__ cuDoubleComplex s_h[32][32];
    __shared__ cuDoubleComplex s_reg[32][32];

    _cupy_channelizer_32x32_complex128_complex128( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_16x16_complex128_complex128( const int n_chans,
                                                   const int n_taps,
                                                   const int n_pts,
                                                   const cuDoubleComplex *__restrict__ x,
                                                   const cuDoubleComplex *__restrict__ h,
                                                   cuDoubleComplex *__restrict__ y ) {

    __shared__ cuDoubleComplex s_h[32][32];
    __shared__ cuDoubleComplex s_reg[32][32];

    _cupy_channelizer_32x32_complex128_complex128( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}

extern "C" __global__ void __launch_bounds__( 1024 )
    _cupy_channelizer_32x32_complex128_complex128( const int n_chans,
                                                   const int n_taps,
                                                   const int n_pts,
                                                   const cuDoubleComplex *__restrict__ x,
                                                   const cuDoubleComplex *__restrict__ h,
                                                   cuDoubleComplex *__restrict__ y ) {

    __shared__ cuDoubleComplex s_h[32][32];
    __shared__ cuDoubleComplex s_reg[32][32];

    _cupy_channelizer_32x32_complex128_complex128( n_chans, n_taps, n_pts, x, h, y, s_h, s_reg );
}
#endif