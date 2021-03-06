/*
 ============================================================================
 Name        : NTTFFTCUDA.cu
 Author      : Owen
 Version     :
 Copyright   : Your copyright notice
 Description : CUDA implementation of integer NTT using CG FFT algorithm
 ============================================================================
 */

#include <iostream>
#include <numeric>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <stdint.h>
#include <math.h>

static void CheckCudaErrorAux (const char *, unsigned, const char *, cudaError_t);
void ProcessandTime(const int size, const int bpe, const int thread_limit);
void initialize(uint32_t* arr, int size, const int bpe);
#define CUDA_CHECK_RETURN(value) CheckCudaErrorAux(__FILE__,__LINE__, #value, value)
/**
 * CUDA kernel that computes the integer FFT of an array of unsigned integers
 */
// both of the following constants must be a power of two
// the first part takes care of the first stages before the shuffling and the
// element transfer from shared memory to global memory
__global__ void MulSMNTTKernel1(uint32_t *data, const short gridSizeSh, const short th_sec, short curr_k, short k, int mod, const uint32_t* g, bool repos) {
	const int BLOCK_SIZE = blockDim.x;	// the offset given for the second part of shared memory
	if (threadIdx.x < BLOCK_SIZE){	// for maximum performance, the last threadIdx.xshould be a multiple of 32 (minus 1 since it starts from 0)
		uint32_t tempvar; 	  // a temporary variable to manage subtractions and hold temporary data
		short i = threadIdx.x >> 1;
		short j = threadIdx.x & 1;	// even or odd thread
		// used for twiddle factor indexing
		short l = k - curr_k - 1;
		short m = i & 1;	// helps in indexing for each thread in a block
		short elem;
		short b_twid = blockIdx.x << (l - 1);	// twiddle factor indexing for each block
		if(BLOCK_SIZE >= gridDim.x)
			elem = threadIdx.x+ (blockIdx.x << th_sec) + (((threadIdx.x >> th_sec) * (gridDim.x - 1)) << th_sec);
		else
			elem = blockIdx.x + (threadIdx.x << gridSizeSh);
		short p, tmp, x, offx, x1, twid_1, twid_2, twid_index = 0;
		// sign takes care of the operations for even (addition)
		// and odd (subtraction) threads
		short sign = ((-2) * j) + 1;  // can be 1 or -1
		// temporary array to store intermediate data
		extern __shared__ uint32_t final_temp[];
		extern __shared__ uint32_t temp_data[];

		// copy data from global memory to shared memory
		final_temp[threadIdx.x] = data[elem];
		__syncthreads();	// ensure that the shared memory is properly populated


		// stg is the stage (or epoch)
		// k is the number of stages in the computation
		for(short stg = 1; stg <= curr_k; stg++){
			p = BLOCK_SIZE >> stg;	// this variable will help in indexing
			// indexing
			tmp = i + ((i >> (k - curr_k - stg)) * (1 << (k - curr_k - stg)));
			x = tmp + (j * p);
			offx = BLOCK_SIZE + x;	// use this to index second part of shared memory (temp_data[])
			x1 = x + (sign * p);
			if(repos){
				twid_1 = (blockIdx.x + (i << gridSizeSh)) * (curr_k - stg);		// twiddle for stage 1
				twid_2 = ((l - 1) * ((!m * b_twid) + (m * (b_twid + BLOCK_SIZE))) + (curr_k - l) * (blockIdx.x << l)) * (stg - 1);	// twiddle for stage 2
				// twid_index manages the indexing of the twiddle factors
				twid_index =  twid_1 + twid_2;
			}
			// since the value should be unsigned, a subtraction cannot result in a negative number
			// so we add the modulus to the number being subtracted to prevent that from happening
			tempvar = final_temp[x1] + mod;
			// addition and subtraction is taken care of here
			// modulus is done after addition/subtraction
			temp_data[offx] = (tempvar + (sign * final_temp[x])) % mod;
			// shift by twiddle factor and perform modulus
			if(repos){
				temp_data[offx] <<= j * g[twid_index];
				temp_data[offx] %= mod;
			}
			final_temp[x] = temp_data[offx];
			__syncthreads();
		}
		// shuffle data from shared to global memory
		data[elem] = final_temp[threadIdx.x];
	}
}

// second part of the NTT which takes care of the rest of the stages using constant geometry
__global__ void MulSMCGNTTKernel2(uint32_t *data, const short gridSizeSh, short curr_k, short k, int mod, uint32_t* g, bool repos) {
	unsigned short glob_idx = blockIdx.x * blockDim.x + threadIdx.x;
	const int BLOCK_SIZE = blockDim.x;	// the offset given for the second part of shared memory
	if (threadIdx.x < BLOCK_SIZE){	// for maximum performance, the last threadIdx.xshould be a multiple of 32 (minus 1 since it starts from 0)
		uint32_t tempvar;
		short Ndiv2 = BLOCK_SIZE >> 1;
		short j = threadIdx.x & 1;	// even or odd thread
		// x and y are the input indexes
		short x = threadIdx.x >> 1;
		short y = x + Ndiv2;
		short z = threadIdx.x;	// output index
		short j_sign = -(j << 1) + 1;
		short twid_index;
		// temporary array to store intermediate data
		extern __shared__ uint32_t final_temp[];
		extern __shared__ uint32_t temp_data[];

		// copy data from global memory to shared memory
		final_temp[threadIdx.x] = data[glob_idx];
		__syncthreads();	// ensure that the shared memory is properly populate

		// stg is the stage (or epoch)
		// k is the number of stages in the computation
		for(short stg = curr_k; stg <= k; stg = stg + 2){	// stage increments by 2 each time
			tempvar = final_temp[x] + mod;
			// step 1
			// make the subtraction unable to result in a negative number by
			// forcing the first number to be greater than the second if it is not already


			temp_data[z + BLOCK_SIZE] = (tempvar + (j_sign * final_temp[y])) % mod;
			if(repos){
				twid_index = (x >> (stg - 1)) * (1 << (stg - 1)) * repos;
				temp_data[z + BLOCK_SIZE] <<= j * g[twid_index];
				temp_data[z + BLOCK_SIZE] %= mod;
			}
			__syncthreads();	// this makes sure that the final_temp array is read from before it is written to
			if(stg != k){	// all threads will go through one of these branches (no warp divergence here)
				// calculate twiddle factor index
				twid_index = (x >> stg) * (1 << stg);;
				tempvar = temp_data[x + BLOCK_SIZE] + mod;

				// step 2
				final_temp[z] = (tempvar + (j_sign * temp_data[y + BLOCK_SIZE])) % mod;
				if(repos)
					final_temp[z] = (final_temp[z] << (j * g[twid_index])) % mod;
			}
			else
				final_temp[z] = temp_data[z + BLOCK_SIZE];
			__syncthreads();
		}

		// write finished data from shared to global memory
		data[glob_idx] = final_temp[threadIdx.x];
	}
}

// kernel for the inverse NTT FFT using constant geometry
__global__ void MulSMCGINTTKernel1(uint32_t *data, const int NTT_SIZE, const short BITS_PER_ELEM, const short gridSizeSh, short curr_k, short k, int mod, uint32_t* g, bool repos, bool fin) {
	unsigned short glob_idx = blockIdx.x * blockDim.x + threadIdx.x;
	const int BLOCK_SIZE = blockDim.x;	// the offset given for the second part of shared memory
	if (threadIdx.x < BLOCK_SIZE){	// for maximum performance, the last threadIdx.x should be a multiple of 32 (minus 1 since it starts from 0)
		uint32_t tempz1;
		short Ndiv2 = BLOCK_SIZE >> 1;
		short j = threadIdx.x & 1;	// even or odd thread
		// x and y are the input indices
		short x = threadIdx.x >> 1;
		short y = x + Ndiv2;
		short out = (x * !j) + (y * j);	// choose y or j
		short z = threadIdx.x - j;	// input index
		short j_sign = -(j << 1) + 1;
		short twid_index;
		// temporary array to store intermediate data
		extern __shared__ uint32_t final_temp[];
		extern __shared__ uint32_t temp_data[];

		// copy data from global memory to shared memory
		final_temp[threadIdx.x] = data[glob_idx];
		__syncthreads();	// ensure that the shared memory is properly populated

		// stg is the stage (or epoch)
		// k is the number of stages in the computation
		for(short stg = k; stg >= curr_k; stg = stg - 2){	// stage increments by 2 each time
			// make the subtraction unable to result in a negative number by
			// forcing the first number to be greater than the second if it is not already
			tempz1 = final_temp[z] + mod;
			// step 1

			if(repos){
				twid_index = (x >> (stg - 1)) * (1 << (stg - 1));
				temp_data[out + BLOCK_SIZE] = (tempz1 + j_sign * ((final_temp[z + 1] << g[twid_index]) % mod)) % mod;
			}
			else
				temp_data[out + BLOCK_SIZE] = (tempz1 + j_sign * final_temp[z + 1]) % mod;
			__syncthreads();	// this makes sure that the final_temp array is read from before it is written to
			if(stg != curr_k){	// all threads will go through one of these branches (no warp divergence here)
				tempz1 = temp_data[z + BLOCK_SIZE] + mod;

				// step 2
				if(repos){
					// calculate twiddle factor index
					twid_index = (x >> (stg - 2)) * (1 << (stg - 2));
					final_temp[out] = (tempz1 + j_sign * ((temp_data[z + BLOCK_SIZE + 1] << g[twid_index]) % mod)) % mod;
				}
				else
					final_temp[out] = (tempz1 + j_sign * temp_data[z + BLOCK_SIZE + 1]) % mod;
			}
			else
				final_temp[out] = temp_data[out + BLOCK_SIZE];
			__syncthreads();
		}

		// no thread divergence here also
		if(fin){	// if there is only 1 SM finish at this kernel
			// divide each element by N
			short t = (BITS_PER_ELEM << 1) - k; // convert division into multiplication
			uint32_t ls, rs;
			short size = sizeof(uint32_t) << 3; // multiply 4 bytes by 8 in this case (32 bits)
			bool rt_shift = false;	// should the shift be to the right and rotate bits?
			if(t < 0){	// if t is negative, all shifts are to the right
				uint32_t mask = t >> (size - 1);     // make a mask of the sign bit
				t ^= mask;                   // toggle the bits
				t += mask & 1;               // add one
				rt_shift = true;
			}
			short temp_sh;
			short shift = size - (BITS_PER_ELEM + 1);
			// shifting will be done in an optimized manner
			if (shift > t)
				shift = t;	// if t is less than the maximum shift amount, then assign the shift amount to be t
			temp_sh = shift;
			for (short m = 0; m < t; m += shift) {
				shift = temp_sh;	// assign the shift value from the previous iteration

				// there is no thread divergence here since all threads execute the same branch
				if(!rt_shift){	// normal left shift
					final_temp[threadIdx.x] <<= shift;
				}
				else{	// right shift and bit rotation
					rs = final_temp[threadIdx.x] >> shift;
					ls = final_temp[threadIdx.x] << (size - shift);
					final_temp[threadIdx.x] = rs | ls;
				}
				final_temp[threadIdx.x] %= mod;
				if (t - shift <= (BITS_PER_ELEM - 1))
					temp_sh = t - shift;	// all remaining shifts will be done after modulus
			}

			// copy final data from shared memory to global memory
			if(repos)
				data[(NTT_SIZE - glob_idx) % NTT_SIZE] = final_temp[threadIdx.x];
			else
				data[glob_idx] = final_temp[threadIdx.x];
		}
		else{
			// copy from shared memory to global memory in a coalesced manner
			data[glob_idx] = final_temp[threadIdx.x];
		}
	}
}

// shuffles data from global memory to shared memory and computes last set of stages
__global__ void MulSMINTTKernel2(uint32_t *data, const int NTT_SIZE, const short BITS_PER_ELEM, const short gridSizeSh, const short th_sec, short curr_k, short k, int mod, const uint32_t* g, bool repos) {
	const int BLOCK_SIZE = NTT_SIZE >> gridSizeSh;	// the offset given for the second part of shared memory
	if (threadIdx.x < BLOCK_SIZE){	// for maximum performance, the last threadIdx.xshould be a multiple of 32 (minus 1 since it starts from 0)
		uint32_t tempvar; 	  // a temporary variable to manage subtractions and hold temporary data
		short i = threadIdx.x >> 1;
		short j = threadIdx.x & 1;	// even or odd thread
		short l = k - curr_k - 1;
		short m = i & 1;
		short elem;
		short b_twid = blockIdx.x << (l - 1);	// twiddle factor indexing for each block
		if(BLOCK_SIZE >= gridDim.x)
			elem = threadIdx.x+ (blockIdx.x << th_sec) + (((threadIdx.x >> th_sec) * (gridDim.x - 1)) << th_sec);
		else
			elem = blockIdx.x + (threadIdx.x << gridSizeSh);
		short x, tmp, p, offx, x1, twid_1, twid_2, twid_index;
		// sign takes care of the operations for even (addition)
		// and odd (subtraction) threads
		short sign = ((-2) * j) + 1;  // can be 1 or -1
		// temporary array to store intermediate data
		extern __shared__ uint32_t final_temp[];
		extern __shared__ uint32_t temp_data[];

		// copy data from global memory to shared memory
		final_temp[threadIdx.x] = data[elem];
		__syncthreads();	// ensure that the shared memory is properly populated
		// stg is the stage (or epoch)
		// k is the number of stages in the computation
		for(short stg = curr_k; stg >= 1; stg--){
			p = BLOCK_SIZE >> stg;	// this variable will help in indexing
			// indexing
			tmp = i + ((i >> (k - curr_k - stg)) * (1 << (k - curr_k - stg)));
			x = tmp + (j * p);
			offx = BLOCK_SIZE + x;
			x1 = x + (sign * p);
			if(repos){
				twid_1 = (blockIdx.x + (i << gridSizeSh)) * (curr_k - stg);		// twiddle for stage 1
				twid_2 = ((l - 1) * ((!m * b_twid) + (m * (b_twid + BLOCK_SIZE))) + (curr_k - l) * (blockIdx.x << l)) * (stg - 1);	// twiddle for stage 2

				// twid_index manages the indexing of the twiddle factors
				twid_index =  twid_1 + twid_2;
				// shift by twiddle factor and perform modulus
				tempvar = (final_temp[x1] << (!j * g[twid_index])) % mod;
				temp_data[offx] = final_temp[x] << (j * g[twid_index]);
				temp_data[offx] %= mod;
			}
			else{
				tempvar = final_temp[x1];
				temp_data[offx] = final_temp[x];
			}

			// since the value should be unsigned, a subtraction cannot result in a negative number
			// so we add the modulus to the number being subtracted to prevent that from happening
			tempvar += mod;
			// addition and subtraction is taken care of here
			// modulus is done after addition/subtraction
			temp_data[offx] = (tempvar + (sign * temp_data[offx])) % mod;
			final_temp[x] = temp_data[offx];
			// new data is ready for next stage
			__syncthreads();
		}

		// divide each element by N
		short t = (BITS_PER_ELEM << 1) - k; // convert division into multiplication
		uint32_t ls, rs;
		short size = sizeof(uint32_t) << 3; // multiply 4 bytes by 8 in this case (32 bits)
		bool rt_shift = false;	// should the shift be to the right and rotate bits?
		if(t < 0){	// if t is negative, all shifts are to the right
			uint32_t mask = t >> (size - 1);     // make a mask of the sign bit
			t ^= mask;                   // toggle the bits
			t += mask & 1;               // add one
			rt_shift = true;
		}
		short temp_sh;
		short shift = size - (BITS_PER_ELEM + 1);
		// shifting will be done in an optimized manner
		if (shift > t)
			shift = t;	// if t is less than the maximum shift amount, then assign the shift amount to be t
		temp_sh = shift;
		for (m = 0; m < t; m += shift) {
			shift = temp_sh;	// assign the shift value from the previous iteration

			// there is no thread divergence here since all threads execute the same branch
			if(!rt_shift){	// normal left shift
				final_temp[threadIdx.x] <<= shift;
			}
			else{	// right shift and bit rotation
				rs = final_temp[threadIdx.x] >> shift;
				ls = final_temp[threadIdx.x] << (size - shift);
				final_temp[threadIdx.x] = rs | ls;
			}
			final_temp[threadIdx.x] %= mod;
			if (t - shift <= (BITS_PER_ELEM - 1))
				temp_sh = t - shift;	// all remaining shifts will be done after modulus
		}

		// copy final data from shared memory to global memory
		if(repos)
			data[(NTT_SIZE - elem) % NTT_SIZE] = final_temp[threadIdx.x];
		else
			data[elem] = final_temp[threadIdx.x];
	}
}

/*! \name GPU function caller and process timing function */
void ProcessandTime(const int size, const int bpe, const int thlimit){
	// define NTT variables
	double intervalNTT = 0, intervalINTT = 0;
	float NTTms, iNTTms;
	cudaEvent_t NTTstart, NTTstop, INTTstart, INTTstop;
	cudaEventCreate(&NTTstart);
	cudaEventCreate(&NTTstop);
	cudaEventCreate(&INTTstart);
	cudaEventCreate(&INTTstop);

	short kt = log2((double)size);
	int i;	// index for traversing through the arrays
	int modulus = (1 << bpe) + 1; // prime number for modulo arithmetic
	int rt_unity = 2 * bpe / size; // calculate # bits for root of unity
	// these flags determine whether the IFFT repositions the elements
	// and whether the result of the IFFT matches the input array or not, respectively
	bool repos_flag = true, flag = true;
	int runs = 1E3;	// number of times each kernel function is executed
	uint32_t *in = new uint32_t[size];
	uint32_t *NTT_out = new uint32_t[size];
	uint32_t *INTT_out = new uint32_t[size];
	uint32_t* gpuNTTData, *gpuINTTData, *gpuTwid;
	CUDA_CHECK_RETURN(cudaMalloc((void **)&gpuNTTData, sizeof(uint32_t) * size));
	CUDA_CHECK_RETURN(cudaMalloc((void **)&gpuTwid, sizeof(uint32_t)*size / 2));
	CUDA_CHECK_RETURN(cudaMalloc((void **)&gpuINTTData, sizeof(uint32_t)*size));
	uint32_t twiddle[size / 2];	// pre-compute twiddle factor array
	if(!rt_unity)
		repos_flag = false;

	for(int i = 0; i < size / 2; i++){
		twiddle[i] = rt_unity * i;
	}
	int blk_size;
	bool isSingleSM = false;
	if(size <= thlimit){
		blk_size = size;
		isSingleSM = true;
	}
	else
		blk_size = thlimit;
	static const int BLOCK_SIZE = blk_size;	// amount of threads in each block
	const int blockCount = (size) / BLOCK_SIZE;	// amount of blocks in a grid
	short k = log2((double)blockCount);	// first kernel covers first k stages only out of kt for FFT, and vice-versa for IFFT kernels
	const short gridSizeSh = logf(blockCount) / logf(2);
	short coal_segment = BLOCK_SIZE >> gridSizeSh;
	coal_segment = log2((float)coal_segment);
	std::cout << "Launching kernels with " << blockCount << " block(s), each with " << BLOCK_SIZE << " threads." << std::endl;
	srand(time(NULL));	// generate the seed for the pseudo-random number generator
	for (int j = 0; j < runs; j++) {
		initialize(in, modulus, size);

		CUDA_CHECK_RETURN(cudaMemcpy(gpuNTTData, in, sizeof(uint32_t)*size, cudaMemcpyHostToDevice));
		CUDA_CHECK_RETURN(cudaMemcpy(gpuTwid, twiddle, sizeof(uint32_t)*size/2, cudaMemcpyHostToDevice));

		cudaEventRecord(NTTstart);
		if(!isSingleSM){
			// computes first k stages and shuffles data from shared memory to global memory
			MulSMNTTKernel1<<<blockCount, BLOCK_SIZE, 2 * BLOCK_SIZE * sizeof(uint32_t)>>> (gpuNTTData, gridSizeSh, coal_segment, k, kt, modulus, gpuTwid, repos_flag);
		}
		// shuffles data from global memory to shared memory and computes last set of stages
		MulSMCGNTTKernel2<<<blockCount, BLOCK_SIZE, 2 * BLOCK_SIZE * sizeof(uint32_t)>>> (gpuNTTData, gridSizeSh, k + 1, kt, modulus, gpuTwid, repos_flag);
		cudaEventRecord(NTTstop);

		CUDA_CHECK_RETURN(cudaMemcpy(NTT_out, gpuNTTData, sizeof(uint32_t) * size, cudaMemcpyDeviceToHost));
		CUDA_CHECK_RETURN(cudaMemcpy(gpuINTTData, NTT_out, sizeof(uint32_t)*size, cudaMemcpyHostToDevice));
		cudaEventSynchronize(NTTstop);
		cudaEventElapsedTime(&NTTms, NTTstart, NTTstop);
		cudaEventRecord(INTTstart);
		// computes first stages and shuffles data from shared memory to global memory
		MulSMCGINTTKernel1<<<blockCount, BLOCK_SIZE, 2 * BLOCK_SIZE * sizeof(uint32_t)>>> (gpuINTTData, size, bpe, gridSizeSh, k + 1, kt, modulus, gpuTwid, repos_flag, isSingleSM);
		if(!isSingleSM){
			// shuffles data from global memory to shared memory and computes last set of stages
			MulSMINTTKernel2<<<blockCount, BLOCK_SIZE, 2 * BLOCK_SIZE * sizeof(uint32_t)>>> (gpuINTTData, size, bpe, gridSizeSh, coal_segment, k, kt, modulus, gpuTwid, repos_flag);
		}
		cudaEventRecord(INTTstop);

		CUDA_CHECK_RETURN(cudaMemcpy(INTT_out, gpuINTTData, sizeof(uint32_t)*size, cudaMemcpyDeviceToHost));

		cudaEventSynchronize(INTTstop);
		cudaEventElapsedTime(&iNTTms, INTTstart, INTTstop);

		// total time taken is summed up
		intervalNTT += NTTms;
		intervalINTT += iNTTms;


		for (i = 0; i < size; i++) {
			if (in[i] != INTT_out[i]) {
				flag = false;
				break;
			}
		}

		if (!flag) {
			std::cout << "j = " << j << ", i = " << i << "\nin = " << in[i] << ", out = " << INTT_out[i] << std::endl;
			break;
		}
	}

	if (flag){
		std::cout << "NTT matched. Average time taken for NTT is: " << intervalNTT << " microseconds" << std::endl;
		std::cout << "Average time taken for INTT is: " << intervalINTT << " microseconds" << std::endl;
	}

	// clean up
	cudaEventDestroy(NTTstart);
	cudaEventDestroy(NTTstop);
	cudaEventDestroy(INTTstart);
	cudaEventDestroy(INTTstop);
	CUDA_CHECK_RETURN(cudaFree(gpuNTTData));
	CUDA_CHECK_RETURN(cudaFree(gpuINTTData));
	CUDA_CHECK_RETURN(cudaFree(gpuTwid));
	delete[] in;
	delete[] NTT_out;
	delete[] INTT_out;
	return;
}

// @}


/* \name Array initializer function */
void initialize(uint32_t* in, int mod, const int size)
{
	for (int i = 0; i < size; i++)
	{
		in[i] = (uint32_t)(rand() % mod);
	}
}

// @}

int main(int argc, char *argv[])
{
	std::cerr << "NTT FFT with constant geometry" << std::endl;
	const int NTT_SIZE = atoi(argv[1]);
	const int BITS_PER_ELEM = atoi(argv[2]);
	const int TH_LIM = atoi(argv[3]);
	// check if both of the required arguments are powers of two
	double chk1 = log2((double)NTT_SIZE);
	double chk2 = log2((double)BITS_PER_ELEM);
	double chk3 = (double)logf(TH_LIM) / logf(2);
	if (argc != 4 || chk1 != round(chk1) || chk2 != round(chk2) || chk3 != round(chk3) ||  TH_LIM < 0 || TH_LIM > 1024 || BITS_PER_ELEM > 16
				|| NTT_SIZE/TH_LIM > TH_LIM || NTT_SIZE <= 1 || BITS_PER_ELEM <= 1)
	{
	  std::cerr << "Usage: " << argv[0]
			<< " <NTT size> <Bits per element> <thread limit per block> " << std::endl;
	  exit(1);
	}
	std::cout << "Computing..." << std::endl;
	ProcessandTime(NTT_SIZE, BITS_PER_ELEM, TH_LIM);
	return 0;
}

/**
 * Check the return value of the CUDA runtime API call and exit
 * the application if the call has failed.
 */
static void CheckCudaErrorAux (const char *file, unsigned line, const char *statement, cudaError_t err)
{
	if (err == cudaSuccess)
		return;
	std::cerr << statement<<" returned " << cudaGetErrorString(err) << "("<<err<< ") at "<<file<<":"<<line << std::endl;
	exit (1);
}
