/*
  Copyright (c) 2010 Toru Tamaki

  Permission is hereby granted, free of charge, to any person
  obtaining a copy of this software and associated documentation
  files (the "Software"), to deal in the Software without
  restriction, including without limitation the rights to use,
  copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the
  Software is furnished to do so, subject to the following
  conditions:

  The above copyright notice and this permission notice shall be
  included in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
  OTHER DEALINGS IN THE SOFTWARE.
*/


#include "cudaMem.h"

#include <iostream>
#include <algorithm>
#include <cstdio>

//cuda
#include <helper_cuda.h>
#include <helper_cuda_drvapi.h>
#include <helper_cuda_gl.h>
#include <helper_timer.h>
#include <helper_string.h>
#include <helper_math.h>
#include <helper_image.h>
#include <helper_functions.h>
#include <device_launch_parameters.h>
#include <device_functions.h>
#include <cuda_runtime_api.h>
#include <cuda.h>

#include "cublas.h"

// uncomment if you do not use the viewer.
//#define NOVIEWER

#include "3dregistration.h"
#include "engine.h"

using namespace std;





	

/***************************/
__global__ static void
d_updateA(int rowsA, int colsA, int pitchA,
	const float* d_Xx, const float* d_Xy, const float* d_Xz, 
	const float* d_Yx, const float* d_Yy, const float* d_Yz,
	const float* d_R, const float* d_t,
	float* d_A,
	float sigma_p2){


  int r =  blockIdx.x * blockDim.x + threadIdx.x;
  int c =  blockIdx.y * blockDim.y + threadIdx.y;

  // Shared memory
  __shared__ float XxShare[BLOCK_SIZE];
  __shared__ float XyShare[BLOCK_SIZE];
  __shared__ float XzShare[BLOCK_SIZE];
  __shared__ float YxShare[BLOCK_SIZE];
  __shared__ float YyShare[BLOCK_SIZE];
  __shared__ float YzShare[BLOCK_SIZE];
  __shared__ float RShare[9]; // BLOCK_SIZE >= 9 is assumed
  __shared__ float tShare[3]; // BLOCK_SIZE >= 3 is assumed

  if(threadIdx.y == 0)
    if(// 0 <= threadIdx.x &&  // threadIdx.x is unsigned int, so always positive
       threadIdx.x < 9){
      RShare[threadIdx.x] = d_R[threadIdx.x];
      if(threadIdx.x < 3)
	tShare[threadIdx.x] = d_t[threadIdx.x];
    }

  if(r < rowsA && c < colsA){ // check for only inside the matrix A

    if(threadIdx.x == 0){
      XxShare[threadIdx.y] = d_Xx[c];
      XyShare[threadIdx.y] = d_Xy[c];
      XzShare[threadIdx.y] = d_Xz[c];
    }
    if(threadIdx.y == 0){
      YxShare[threadIdx.x] = d_Yx[r];
      YyShare[threadIdx.x] = d_Yy[r];
      YzShare[threadIdx.x] = d_Yz[r];
    }

    __syncthreads();

#define Xx XxShare[threadIdx.y]
#define Xy XyShare[threadIdx.y]
#define Xz XzShare[threadIdx.y]
#define Yx YxShare[threadIdx.x]
#define Yy YyShare[threadIdx.x]
#define Yz YzShare[threadIdx.x]
#define R(i) RShare[i]
#define t(i) tShare[i]

// #define Euclid(a,b,c) ((a)*(a)+(b)*(b)+(c)*(c))
//     float tmp =
//       Euclid(Xx - (R(0)*Yx + R(1)*Yy + R(2)*Yz + t(0)),
//              Xy - (R(3)*Yx + R(4)*Yy + R(5)*Yz + t(1)),
//              Xz - (R(6)*Yx + R(7)*Yy + R(8)*Yz + t(2)) );
    
//     tmp = expf(-tmp/sigma_p^2)


     float tmpX = Xx - (R(0)*Yx + R(1)*Yy + R(2)*Yz + t(0));
     float tmpY = Xy - (R(3)*Yx + R(4)*Yy + R(5)*Yz + t(1));
     float tmpZ = Xz - (R(6)*Yx + R(7)*Yy + R(8)*Yz + t(2));

    __syncthreads();

     tmpX *= tmpX;
     tmpY *= tmpY;
     tmpZ *= tmpZ;

     tmpX += tmpY;
     tmpX += tmpZ;

     tmpX /= sigma_p2;
     tmpX = expf(-tmpX);


    //float *A = (float*)((char*)d_A + c * pitchMinBytes) + r;

    d_A[c * pitchA + r] = tmpX;
  }

}
/***************************/

/***************************/
__global__ static void
d_normalizeRowsOfA(int rowsA, int colsA, int pitchA,
		 float *d_A,
		 const float *d_C
		 ){
  
  int r =  blockIdx.x * blockDim.x + threadIdx.x;
  int c =  blockIdx.y * blockDim.y + threadIdx.y;

  // Shared memory
  __shared__ float d_CShare[BLOCK_SIZE];


  if(r < rowsA && c < colsA){ // check for only inside the matrix A

    if(threadIdx.y == 0)
      d_CShare[threadIdx.x] = d_C[r];

    __syncthreads();

    if(d_CShare[threadIdx.x] > 10e-7f)
      // each element in A is normalized C, then squre-rooted
      d_A[c * pitchA + r] = sqrtf( d_A[c * pitchA + r] / d_CShare[threadIdx.x] );
    else
      d_A[c * pitchA + r] = 1.0f/colsA; // ad_hoc code to avoid 0 division

    __syncthreads();

  }

}
/***************************/

/***************************/
__global__ static void
d_elementwiseDivision(int Xsize,
		    float* d_Xx, float* d_Xy, float* d_Xz,
		    const float* d_lambda){

  int x =  blockIdx.x * blockDim.x + threadIdx.x;

  if(x < Xsize){ // check for only inside X
    float l_lambda = d_lambda[x];
    d_Xx[x] /= l_lambda;
    d_Xy[x] /= l_lambda;
    d_Xz[x] /= l_lambda;
  }
}
/***************************/

/***************************/
__global__ static void
d_elementwiseMultiplication(int Xsize,
			  float* d_Xx, float* d_Xy, float* d_Xz,
			  const float* d_lambda){

  int x =  blockIdx.x * blockDim.x + threadIdx.x;

  if(x < Xsize){ // check for only inside X
    float l_lambda = d_lambda[x];
    d_Xx[x] *= l_lambda;
    d_Xy[x] *= l_lambda;
    d_Xz[x] *= l_lambda;
  }
}
/***************************/

/***************************/
__global__ static void
d_centeringXandY(int rowsA,
	       const float* d_Xc, const float* d_Yc,
	       const float* d_Xx, const float* d_Xy, const float* d_Xz,
	       const float* d_Yx, const float* d_Yy, const float* d_Yz,
	       float* d_XxCenterd, float* d_XyCenterd, float* d_XzCenterd,
	       float* d_YxCenterd, float* d_YyCenterd, float* d_YzCenterd
	       ){

  // do for both X and Y at the same time
  
  int r =  blockIdx.x * blockDim.x + threadIdx.x;

  // Shared memory
  __shared__ float Xc[3];
  __shared__ float Yc[3];

  if(threadIdx.x < 6) // assume blocksize >= 6
    if(threadIdx.x < 3) 
      Xc[threadIdx.x] = d_Xc[threadIdx.x];
    else
      Yc[threadIdx.x - 3] = d_Yc[threadIdx.x - 3];


  if(r < rowsA){ // check for only inside the vectors

    __syncthreads();

    d_XxCenterd[r] = d_Xx[r] - Xc[0];
    d_XyCenterd[r] = d_Xy[r] - Xc[1];
    d_XzCenterd[r] = d_Xz[r] - Xc[2];

    d_YxCenterd[r] = d_Yx[r] - Yc[0];
    d_YyCenterd[r] = d_Yy[r] - Yc[1];
    d_YzCenterd[r] = d_Yz[r] - Yc[2];

    __syncthreads();

  }
}
/***************************/









/************************/
/*		EM-ICP function	*/
void emicp(	int Xsize, int Ysize,
			float *h_X, float *d_X, float *d_Xx, float *d_Xy, float *d_Xz,
			float* h_Y, float *d_Y, float *d_Yx, float *d_Yy, float *d_Yz,
			float* h_R, float *d_R, float* h_t, float *d_t,
			float* h_S, float *d_S,
			float *h_Xc, float *d_Xc, float *h_Yc, float *d_Yc,
			float *h_one, float *d_one,
			float *d_A,
			float *d_Xprime, float *d_XprimeX, float *d_XprimeY, float *d_XprimeZ,
			float *d_XprimeCenterd, float *d_XprimeCenterdX, float *d_XprimeCenterdY, float *d_XprimeCenterdZ,
			float *d_YCenterd, float *d_YCenterdX, float *d_YCenterdY, float *d_YCenterdZ,
			float *d_C, float *d_lambda,
			int	maxXY, int rowsA, int colsA, int pitchA,
			registrationParameters param,
			bool *error,
			bool *allocateMemory
	   ){

	
	//
	// initialize paramters
	//
	float sigma_p2 = param.sigma_p2;
	float sigma_inf = param.sigma_inf;
	float sigma_factor = param.sigma_factor;
	float d_02 = param.d_02;


	// pitchA:	leading dimension of A, which is ideally equal to rowsA,
	//          but actually larger than that.

	//
	// memory allocation
	//
	

	//
	// initializing CUDA
	//
	// CUT_DEVICE_INIT(param.argc, param.argv);	
	
	
	// R, t
	//copyHostToCUDA(R, 9);
	//copyHostToCUDA(t, 3);
	
	

	//for (int j=0; j<9; j++)
	//	printf("%f %f\n", h_R[j], d_R[j]);


	// NOTE on matrix A
	// number of rows:     Ysize, or rowsA
	// number of columns : Xsize, or colsA
	// 
	//                    [0th in X] [1st]  ... [(Xsize-1)] 
	// [0th point in Y] [ A(0,0)     A(0,1) ... A(0,Xsize-1)      ] 
	// [1st           ] [ A(1,0)     A(1,1) ...                   ]
	// ...              [ ...                                     ]
	// [(Ysize-1)     ] [ A(Ysize-1, 0)     ... A(Ysize-1,Xsize-1)]
	//
	// 
	// CAUTION on matrix A
	// A is allcoated as a column-maijor format for the use of cublas.
	// This means that you must acces an element at row r and column c as:
	// A(r,c) = A[c * pitchA + r]



	//
	// threads
	//

	// for 2D block
	dim3 dimBlockForA(BLOCK_SIZE, BLOCK_SIZE); // a block is (BLOCK_SIZE*BLOCK_SIZE) threads
	dim3 dimGridForA( (pitchA + dimBlockForA.x - 1) / dimBlockForA.x,
			 (colsA  + dimBlockForA.y - 1) / dimBlockForA.y);

	// for 1D block
	int threadsPerBlockForYsize = ICP_CUDA_BLOCK; // a block is 512 threads
	int blocksPerGridForYsize
	 = (Ysize + threadsPerBlockForYsize - 1 ) / threadsPerBlockForYsize;


	//
	// timer
	//

	// timers
	//unsigned int timerUpdateA, timerAfterSVD, timerRT;


	//if(!param.notimer){
	// CUT_SAFE_CALL(cutCreateTimer(&timerUpdateA));
	// CUT_SAFE_CALL(cutCreateTimer(&timerAfterSVD));
	// CUT_SAFE_CALL(cutCreateTimer(&timerRT));
	//}


	//CUT_SAFE_CALL(	cutCreateTimer(&timerTotal));
	//CUDA_SAFE_CALL( cudaThreadSynchronize() );
	//CUT_SAFE_CALL(	cutStartTimer(timerTotal));




	//////////////////////////////////////////////////////////////////////////////////////////
	//																						//
	//												EM-ICP main loop						//
	//																						//
	//////////////////////////////////////////////////////////////////////////////////////////
	float pre_Xc[3], pre_Yc[3];

	while(sigma_p2 > sigma_inf){
		// Remember Xc, Yc
		for (int i=0; i<3; i++) {
			pre_Xc[i] = h_Xc[i];
			pre_Yc[i] = h_Yc[i];
		}

		copyHostToCUDA(R,9);
		copyHostToCUDA(t,3);

		//fprintf(stderr, "%d iter. sigma_p2 %f  ", Titer++, sigma_p2);
		//fprintf(stderr, "time %.10f [s]\n", cutGetTimerValue(timerTotal) / 1000.0f);

#ifndef NOVIEWER
	if(!param.noviewer)
		if (!EngineIteration()) // PointCloudViewer
			break;
#endif

		//
		// UpdateA
		//

		//START_TIMER(timerUpdateA);

		d_updateA <<< dimGridForA, dimBlockForA >>>
			(rowsA, colsA, pitchA,
			 d_Xx, d_Xy, d_Xz, 
			 d_Yx, d_Yy, d_Yz,
			 d_R, d_t, 
			 d_A, sigma_p2);

		//STOP_TIMER(timerUpdateA);


		//
		// Normalization of A
		//

		// cublasSgemv (char trans, int m, int n, float alpha, const float *A, int lda,
		//              const float *x, int incx, float beta, float *y, int incy)
		//    y = alpha * op(A) * x + beta * y,
      
		// A * one vector = vector with elements of row-wise sum
		//     d_A      *    d_one    =>  d_C
		//(rowsA*colsA) *  (colsA*1)  =  (rowsA*1)
		cublasSgemv(	'n',          // char trans
							rowsA, colsA, // int m (rows of A), n (cols of A) ; not op(A)
							1.0f,         // float alpha
							d_A, pitchA,  // const float *A, int lda
							d_one, 1,     // const float *x, int incx
							0.0f,         // float beta
							d_C, 1);      // float *y, int incy


		// void cublasSaxpy (int n, float alpha, const float *x, int incx, float *y, int incy)
		// alpha * x + y => y
		// exp(-d_0^2/sigma_p2) * d_one + d_C => d_C
		float xp = expf(-d_02/sigma_p2);
		cublasSaxpy(rowsA, xp, d_one, 1, d_C, 1);
      
		d_normalizeRowsOfA	<<< dimGridForA, dimBlockForA >>>
			(rowsA, colsA, pitchA, d_A, d_C);


		//
		// update R,T
		//

		///////////////////////////////////////////////////////////////////////////////////// 
		// compute lambda
      
		// A * one vector = vector with elements of row-wise sum
		//     d_A      *    d_one    =>  d_lambda
		//(rowsA*colsA) *  (colsA*1)  =  (rowsA*1)
		
		cublasSgemv(	'n',          // char trans
							rowsA, colsA, // int m (rows of A), n (cols of A) ; not op(A)
							1.0f,         // float alpha
							d_A, pitchA,  // const float *A, int lda
							d_one, 1,     // const float *x, int incx
							0.0f,         // float beta
							d_lambda, 1); // float *y, int incy
		


		// float cublasSasum (int n, const float *x, int incx) 
		float sumLambda = cublasSasum (rowsA, d_lambda, 1);


		///////////////////////////////////////////////////////////////////////////////////// 
		// compute X'

		// cublasSgemm (char transa, char transb, int m, int n, int k, float alpha, 
		//              const float *A, int lda, const float *B, int ldb, float beta, 
		//              float *C, int ldc)
		//   C = alpha * op(A) * op(B) + beta * C,
		//
		// m      number of rows of matrix op(A) and rows of matrix C
		// n      number of columns of matrix op(B) and number of columns of C
		// k      number of columns of matrix op(A) and number of rows of op(B) 

		// A * X => X'
		//     d_A      *    d_X    =>  d_Xprime
		//(rowsA*colsA) *  (colsA*3)  =  (rowsA*3)
		//   m  * k           k * n        m * n   
		cublasSgemm(	'n', 'n', rowsA, 3, colsA,
							1.0f, d_A, pitchA,
							d_X, colsA,
							0.0f, d_Xprime, rowsA);


		// X' ./ lambda => X'
		d_elementwiseDivision 	<<< blocksPerGridForYsize, threadsPerBlockForYsize>>>
			(rowsA, d_XprimeX, d_XprimeY, d_XprimeZ, d_lambda);


		///////////////////////////////////////////////////////////////////////////////////// 
		//
		// centering X' and Y
		//

		///////////////////////////////////////////////////////////////////////////////////// 
		// find weighted center of X' and Y

		// d_Xprime^T *    d_lambda     =>   h_Xc
		//  (3 * rowsA)   (rowsA * 1)  =  (3 * 1)
		cublasSgemv('t',					// char trans
						rowsA, 3,			// int m (rows of A), n (cols of A) ; not op(A)
						1.0f,					// float alpha
						d_Xprime, rowsA,  // const float *A, int lda
						d_lambda, 1,		// const float *x, int incx
						0.0f,					// float beta
						d_Xc, 1);			// float *y, int incy

		// d_Y^T *    d_lambda     =>   h_Yc
		//  (3 * rowsA)   (rowsA * 1)  =  (3 * 1)
		cublasSgemv('t',				// char trans
						rowsA, 3,		// int m (rows of A), n (cols of A) ; not op(A)
						1.0f,				// float alpha
						d_Y, rowsA,		// const float *A, int lda
						d_lambda, 1,	// const float *x, int incx
						0.0f,				// float beta
						d_Yc, 1);		// float *y, int incy

		// void cublasSscal (int n, float alpha, float *x, int incx)
		// it replaces x[ix + i * incx] with alpha * x[ix + i * incx]
		float invSumLambda = 1/sumLambda;
		cublasSscal (3, invSumLambda, d_Xc, 1);
		cublasSscal (3, invSumLambda, d_Yc, 1);

		


		///////////////////////////////////////////////////////////////////////////////////// 
		// centering X and Y

		// d_Xprime .- d_Xc => d_XprimeCenterd
		// d_Y      .- d_Yc => d_YCenterd
		d_centeringXandY	<<< blocksPerGridForYsize, threadsPerBlockForYsize>>>
			(rowsA, 
			 d_Xc, d_Yc,
			 d_XprimeX, d_XprimeY, d_XprimeZ,
			 d_Yx, d_Yy, d_Yz,
			 d_XprimeCenterdX, d_XprimeCenterdY, d_XprimeCenterdZ,
			 d_YCenterdX, d_YCenterdY, d_YCenterdZ);

		// XprimeCented .* d_lambda => XprimeCented
		d_elementwiseMultiplication	<<< blocksPerGridForYsize, threadsPerBlockForYsize >>>
			(rowsA, d_XprimeCenterdX, d_XprimeCenterdY, d_XprimeCenterdZ, d_lambda);

		///////////////////////////////////////////////////////////////////////////////////// 
		// compute S

		//  d_XprimeCented^T *   d_YCenterd     =>  d_S
		//    (3*rowsA)  *  (rowsA*3)  =  (3*3)
		//   m  * k           k * n        m * n
		cublasSgemm('t', 'n', 3, 3, rowsA,
						1.0f, d_XprimeCenterd, rowsA,
						d_YCenterd, rowsA,
						0.0f, d_S, 3);

		

		///////////////////////////////////////////////////////////////////////////////////// 
		// find RT from S

		//START_TIMER(timerAfterSVD);
		copyCUDAToHost(S,9);
		copyCUDAToHost(Xc,3);
		copyCUDAToHost(Yc,3);

		// Remember the latest value in case of failure
		#define h_Xcx h_Xc[0]
		#define h_Xcy h_Xc[1]
		#define h_Xcz h_Xc[2]
		#define h_Ycx h_Yc[0]
		#define h_Ycy h_Yc[1]
		#define h_Ycz h_Yc[2]		
		if (h_Xcx != h_Xcx || h_Xcy != h_Xcy || h_Xcz != h_Xcz) {
			for (int i=0; i<3; i++)
				h_Xc[i] = pre_Xc[i];
		}
		if (h_Ycx != h_Ycx || h_Ycy != h_Ycy || h_Ycz != h_Ycz) {
			for (int i=0; i<3; i++)
				h_Yc[i] = pre_Yc[i];
		}
		////////////////

		findRTfromS(h_Xc, h_Yc, h_S, h_R, h_t, error);
		if (*error)
			break;

		//STOP_TIMER(timerAfterSVD);

		///////////////////////////////////////////////////////////////////////////////////// 
		// copy R,t to device

		//START_TIMER(timerRT);

		

		//STOP_TIMER(timerRT);

		///////////////////////////////////////////////////////////////////////////////////// 

#ifndef NOVIEWER
		if(!param.noviewer)
			UpdatePointCloud2(Ysize, param.points2, h_Y, h_R, h_t);
#endif


		sigma_p2 *= sigma_factor;
	}


	/////////////////////////////////////////////////////////////////////////////////////////
	/////////////////////////////////////////////////////////////////////////////////////////

	//CUDA_SAFE_CALL( cudaThreadSynchronize() );
	//CUT_SAFE_CALL(	cutStopTimer(timerTotal));

	//fprintf(stderr, "comping time: %.10f [s]\n", cutGetTimerValue(timerTotal) / 1000.0f);

	if(!param.notimer){
		//fprintf(stderr, "comping time: %.10f [s]\n", cutGetTimerValue(timerTotal) / 1000.0f);
		///fprintf(stderr, "Average %.10f [s] for %s\n", cutGetAverageTimerValue(timerUpdateA)  / 1000.0f, "updateA");
		//fprintf(stderr, "Average %.10f [s] for %s\n", cutGetAverageTimerValue(timerAfterSVD) / 1000.0f, "afterSVD");
		//fprintf(stderr, "Average %.10f [s] for %s\n", cutGetAverageTimerValue(timerRT) / 1000.0f, "RT");

		//CUT_SAFE_CALL(cutDeleteTimer(timerTotal));
		//CUT_SAFE_CALL(cutDeleteTimer(timerUpdateA));
		//CUT_SAFE_CALL(cutDeleteTimer(timerAfterSVD));
		//CUT_SAFE_CALL(cutDeleteTimer(timerRT));
	}

}
/***************************/
