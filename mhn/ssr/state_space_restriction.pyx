# distutils: language = c++

# by Stefan Vocht
#
# implement StateSpaceRestriction using Cython
#

cimport cython

from scipy.linalg.cython_blas cimport dcopy, dscal, daxpy, ddot
from libc.stdlib cimport malloc, free
from libc.math cimport exp, log

from mhn.ssr.state_storage cimport State, StateStorage
from mhn.original.PerformanceCriticalCode cimport _compute_inverse, _compute_inverse_t

import numpy as np
cimport numpy as np

np.import_array()

cdef extern from *:
    """
    /*
    Counts number of 1s in binary representation of number x, where x is a 32-bit integer
    Source: https://stackoverflow.com/questions/109023/how-to-count-the-number-of-set-bits-in-a-32-bit-integer
    */
    int count_ones32(uint32_t i){
        i = i - ((i >> 1) & 0x55555555);                                    // add pairs of bits
        i = (i & 0x33333333) + ((i >> 2) & 0x33333333);                     // quads
        i = (i + (i >> 4)) & 0x0F0F0F0F;                                    // groups of 8
        return (i * 0x01010101) >> 24;                                      // horizontal sum of bytes
    }

    /*
    Counts number of 1s in binary representation of number x, where x is a 64-bit integer
    Source: https://en.wikipedia.org/wiki/Hamming_weight 
    */
    int count_ones(long long x) {
        x -= (x >> 1) & 0x5555555555555555LL;             					//put count of each 2 bits into those 2 bits
        x = (x & 0x3333333333333333LL) + ((x >> 2) & 0x3333333333333333LL); //put count of each 4 bits into those 4 bits 
        x = (x + (x >> 4)) & 0x0f0f0f0f0f0f0f0fLL;        					//put count of each 8 bits into those 8 bits 
        return (x * 0x0101010101010101LL) >> 56;  							//returns left 8 bits of x + (x<<8) + (x<<16) + (x<<24) + ... 
    }
    """
    inline int count_ones32(unsigned int u) nogil
    inline int count_ones(long long x) nogil


def count_ones64(long long x):
    """
    Wrapper so that count_ones can be called from a Python script
    """
    return count_ones(x)


cdef int get_mutation_num(State *state):
    """
    Get the number of mutations in a given state
    """
    cdef int mutation_num = 0
    cdef int i

    for i in range(STATE_SIZE):
        mutation_num += count_ones32(state[0].parts[i])

    return mutation_num


# load the function cuda_gradient_and_score if the CUDA compiler is available
IF NVCC_AVAILABLE:
    cdef extern from *:
        """
        #ifdef _WIN32
        #define DLL_PREFIX __declspec(dllexport)
        #else
        #define DLL_PREFIX 
        #endif

        int DLL_PREFIX cuda_gradient_and_score_implementation(double *ptheta, int n, State *mutation_data, int data_size, double *grad_out, double *score_out);
        void DLL_PREFIX get_error_name_and_description(int error, const char **error_name, const char **error_description);
        int DLL_PREFIX cuda_functional();
        """

        int cuda_gradient_and_score_implementation(double *ptheta, int n, State *mutation_data, int data_size, double *grad_out, double *score_out)
        void get_error_name_and_description(int error, const char **error_name, const char **error_description)
        int cuda_functional()


@cython.wraparound(False)
@cython.boundscheck(False)
cdef void restricted_kronvec(double[:, :] theta_mat, int i, double[:] x_vec, State *state, int mutation_num, double *pout, bint diag = False, bint transp = False) nogil:
    """
    This function multiplies the kronecker product described in the original MHN paper in eq.9 with a vector

    :param theta_mat: matrix containing the theta entries
    :param i: vector is multiplied with the ith kronecker product (ith summand in eq. 9 of the original paper) 
    :param x_vec: vector that is multiplied with the kronecker product
    :param state: current state used to compute the gradient
    :param mutation_num: number of mutations present in state
    :param pout: vector which will contain the result of this multiplication
    :param diag: if False, the diagonal of the kronecker product is set to zero
    :param transp: if True, the kronecker product is transposed
    """

    # initialize some constants used in this function
    cdef double[:] theta_i = theta_mat[i, :]
    cdef int n = theta_i.shape[0]
    cdef int nx = 1 << mutation_num
    cdef int nxhalf = nx / 2
    cdef double mOne = -1
    cdef double zero = 0

    cdef int incx = 1
    cdef int incx2 = 2
    cdef int j

    # if we have no diagonal and the ith gene is not mutated, the result is always a zero vector
    if not diag and not (state[0].parts[i >> 5] >> (i & 31)) & 1:
        dscal(&nx, &zero, pout, &incx)
        return

    cdef double *ptmp = <double *> malloc(nx * sizeof(double))
    cdef double *px1
    cdef double *px2
    cdef double *shuffled_vec
    cdef double *old_vec
    cdef double *swap_vec
    cdef double theta

    # for the shuffle algorithm we have to initialize the pointers correctly
    if mutation_num & 1 == 1:
        swap_vec = ptmp
        shuffled_vec = pout
    else:
        swap_vec = pout
        shuffled_vec = ptmp

    old_vec = &x_vec[0]

    cdef int state_copy = state[0].parts[0]

    # use the shuffle algorithm to compute the product of the kronecker product with a vector
    for j in range(n):
        if state_copy & 1:
            dcopy(&nxhalf, old_vec, &incx2, shuffled_vec, &incx)
            dcopy(&nxhalf, old_vec+1, &incx2, shuffled_vec+nxhalf, &incx)

            theta = exp(theta_i[j])
            px1 = shuffled_vec
            px2 = shuffled_vec + nxhalf

            if j == i:
                if not transp:
                    dcopy(&nxhalf, px1, &incx, px2, &incx)
                    dscal(&nxhalf, &theta, px2, &incx)
                    if diag:
                        dcopy(&nxhalf, px2, &incx, px1, &incx)
                        dscal(&nxhalf, &mOne, px1, &incx)
                    else:
                        dscal(&nxhalf, &zero, px1, &incx)
                else:
                    if diag:
                        theta *= -1
                        daxpy(&nxhalf, &mOne, px2, &incx, px1, &incx)
                        dscal(&nxhalf, &theta, px1, &incx)
                        dscal(&nxhalf, &zero, px2, &incx)
                    else:
                        dcopy(&nxhalf,px2,&incx,px1,&incx)
                        dscal(&nxhalf,&theta,px1,&incx)
                        dscal(&nxhalf,&zero,px2,&incx)

            else:
                dscal(&nxhalf, &theta, px2, &incx)
 
            old_vec = shuffled_vec;
            shuffled_vec = swap_vec;
            swap_vec = old_vec;

        elif i == j:
            theta = -exp(theta_i[j])

            # if old_vec is still pointing to x_vec, we have to change it to not alter x_vec
            if old_vec == &x_vec[0]:
                dcopy(&nx, old_vec, &incx, swap_vec, &incx)
                old_vec = swap_vec

            dscal(&nx, &theta, old_vec, &incx)

		# if the mutation state of the next gene is stored on the current state_copy, make a bit shift to the right
		# else state_copy becomes the next integer stored in the given state (x >> 5  <=> x // 32, x & 31 <=> x % 32)
        if (j + 1) & 31:
            state_copy >>= 1
        else:
            state_copy = state[0].parts[(j+1) >> 5]

    free(ptmp)


cdef void restricted_q_vec(double[:, :] theta, double[:] x, State *state, double *yout, bint diag= False, bint transp = False):
    """
    multiplies the matrix Q(ptheta) with the vector x, result is saved in yout

    :param theta: matrix containing the theta entries
    :param x: vector that should be multiplied with Q(ptheta)
    :param state: state representing current tumor sample
    :param yout: array in which the result is stored
    :param diag: if False, the diag of Q is set to zero during multiplication
    :param transp: if True, multiplication is done with the transposed Q
    """

    cdef int n = theta.shape[0]
    cdef int nx = x.shape[0]
    cdef int i
    cdef double one_d = 1
    cdef int one_i = 1
    cdef double zero = 0

    # get the number of mutations present in the given state
    cdef int mutation_num = get_mutation_num(state)

    cdef double *result_vec = <double *> malloc(sizeof(double) * nx)

    # initialize yout with zero
    dscal(&nx, &zero, yout, &one_i)

    for i in range(n):
        restricted_kronvec(theta, i, x, state, mutation_num, result_vec, diag, transp)
        # add result of restricted_kronvec to yout
        daxpy(&nx, &one_d, result_vec, &one_i, yout, &one_i)

    free(result_vec)


@cython.wraparound(False)
@cython.boundscheck(False)
cdef void restricted_q_diag(double[:, :] theta, State *state, double *dg):
    """
    Compute the diagonal of the transition rate matrix Q

    :param theta: matrix containing the theta entries
    :param state: state representing current tumor sample
    :param dg: array in which the diagonal is stored at the end
    """
    cdef int mutation_num = get_mutation_num(state)
    cdef int nx = 1 << mutation_num
    cdef int n = theta.shape[0]
    cdef int i, j
    cdef int state_copy

    cdef double *s = <double *> malloc(nx * sizeof(double))
    cdef int current_length
    cdef double exp_theta
    cdef double d_one = 1
    cdef double zero = 0
    cdef int i_one = 1

    # initialize the diagonal with zero
    dscal(&nx, &zero, dg, &i_one)

    # compute the ith subdiagonal of Q and add it to dg
    for i in range(n):
        state_copy = state[0].parts[0]
        current_length = 1
        s[0] = 1
        # compute the ith subdiagonal of Q 
        for j in range(n):
            if state_copy & 1:
                exp_theta = exp(theta[i, j])
                if i == j:
                    exp_theta *= -1
                    dscal(&current_length, &exp_theta, s, &i_one)
                    dscal(&current_length, &zero, s + current_length, &i_one)
                else:
                    dcopy(&current_length, s, &i_one, s + current_length, &i_one)
                    dscal(&current_length, &exp_theta, s + current_length, &i_one)

                current_length *= 2

            elif i == j:
                exp_theta = - exp(theta[i, j])
                dscal(&current_length, &exp_theta, s, &i_one)

            # if the mutation state of the next gene is stored on the current state_copy, make a bit shift to the right
            # else state_copy becomes the next integer stored in the given state (x >> 5  <=> x // 32, x & 31 <=> x % 32)
            if (j + 1) & 31:
                state_copy >>= 1
            else:
                state_copy = state[0].parts[(j+1) >> 5]

        # add the subdiagonal to dg
        daxpy(&nx, &d_one, s, &i_one, dg, &i_one)

    free(s)


@cython.wraparound(False)
@cython.boundscheck(False)
cdef np.ndarray[np.double_t] restricted_jacobi(double[:, :] theta, double[:] b, State *state, bint transp = False):
    """
    this functions multiplies [I-Q]^(-1) with b

    :param theta: matrix containing the theta entries
    :param b: array that is multiplied with [I-Q]^(-1)
    :param state: state representing current tumor sample
    :param transp: if True, b is multiplied with the transposed [I-Q]^(-1)
    """
    cdef int mutation_num = get_mutation_num(state)
    cdef int nx = 1 << mutation_num
    cdef int z, j
    cdef int i_one = 1
    cdef int zero = 0
    cdef double d_one = 1
    cdef double mOne = -1

    # make x a vector of size nx in which every entry is set to 1/nx,
    # will be the initial guess to the solution for the jacobi method
    cdef np.ndarray[np.double_t] x = np.full(nx, 1 / (1.0 * nx), dtype=np.double)
    cdef double *q_vec_result = <double *> malloc(nx * sizeof(double))

    # compute the diagonal of [I-Q], store it in dg
    cdef double *dg = <double *> malloc(nx * sizeof(double))
    restricted_q_diag(theta, state, dg)             # compute the diagonal of Q
    daxpy(&nx, &d_one, &mOne, &zero, dg, &i_one)    # subtract 1 from each entry to get the diagonal of [Q-I]
    dscal(&nx, &mOne, dg, &i_one)                   # scale with -1 to get the diagonal of [I-Q]

    for z in range(mutation_num+1):
        restricted_q_vec(theta, x, state, q_vec_result, diag=False, transp=transp)
        # add b to the result of q_vec
        daxpy(&nx, &d_one, &b[0], &i_one, q_vec_result, &i_one)
        # divide every entry by its corresponding diagonal entry
        for j in range(nx):
            x[j] = q_vec_result[j] / dg[j]

    free(dg)
    free(q_vec_result)
    return x


cdef compute_restricted_inverse(double[:, :] theta, double *dg, State *state, double[:] b, double[:] xout, bint transp = False):
    """
    this functions multiplies [I-Q]^(-1) with b and is much faster than restricted jacobi
    
    :param theta: matrix containing the theta entries
    :param dg: vector containing the diagonal of [I-Q]
    :param state: state representing current tumor sample
    :param b: array that is multiplied with [I-Q]^(-1)
    :param xout: vector which will contain the result at the end
    :param transp: if True, b is multiplied with the transposed [I-Q]^(-1)
    """
    cdef int n = theta.shape[0]
    cdef int mutation_num = get_mutation_num(state)
    cdef int i, j
    cdef int state_copy

    cdef double *mutated_thetas = <double *> malloc(mutation_num * mutation_num * sizeof(double))
    cdef int *mutation_pos = <int *> malloc(mutation_num * sizeof(int))

    # we can use the compute_inverse functions from the full state-space code
    # we only have to modify theta, such that the theta that we pass to the compute_inverse functions
    # only contains the thetas that correspond to mutated genes in state

    # first get the indices of the mutated genes
    j = 0
    state_copy = state[0].parts[0]
    for i in range(n):
        if state_copy & 1:
            mutation_pos[j] = i
            j += 1
        if (i + 1) & 31:
            state_copy >>= 1
        else:
            state_copy = state[0].parts[(i+1) >> 5]

    # get only the thetas that correspond to mutated genes
    for i in range(mutation_num):
        for j in range(mutation_num):
            mutated_thetas[i*mutation_num + j] = theta[mutation_pos[i], mutation_pos[j]]

    # now simply call the compute_inverse functions with the "mutated" thetas and pass mutation_num instead of n
    if transp:
        _compute_inverse_t(mutated_thetas, mutation_num, dg, &b[0], &xout[0])
    else:
        _compute_inverse(mutated_thetas, mutation_num, dg, &b[0], &xout[0])

    free(mutation_pos)
    free(mutated_thetas)


@cython.wraparound(False)
@cython.boundscheck(False)
cdef double restricted_gradient_and_score(double[:, :] theta, State *state, double[:, :] g):
    """
    Computes a part of the gradient and score corresponding to a given state

    :param theta: matrix containing the theta entries
    :param state: state representing current tumor sample
    :param g: the resulting gradient is stored in this matrix
    :return: part of the total score
    """
    cdef int n = theta.shape[0]
    cdef int mutation_num = get_mutation_num(state)
    cdef int nx = 1 << mutation_num
    cdef int nxhalf = nx / 2
    cdef int incx = 1
    cdef int incx2 = 2
    cdef int incx0 = 0
    cdef double one = 1.
    cdef double mOne = -1.
    cdef np.ndarray[np.double_t] p0 = np.zeros(nx, dtype=np.double)
    p0[0] = 1

    # compute dg, the diagonal of [I-Q]
    cdef double *dg = <double *> malloc(nx * sizeof(double))
    restricted_q_diag(theta, state, dg)         # compute the diagonal of Q
    daxpy(&nx, &one, &mOne, &incx0, dg, &incx)  # subtract 1 from each entry to get the diagonal of [Q-I]
    dscal(&nx, &mOne, dg, &incx)                # scale with -1 to get the diagonal of [I-Q]

    # compute parts of the probability distribution yielded by the current MHN
    cdef np.ndarray[np.double_t] pth = np.empty(nx, dtype=np.double)
    compute_restricted_inverse(theta, dg, state, p0, pth)

    cdef np.ndarray[np.double_t] pD = np.zeros(nx)
    pD[nx-1] = 1 / pth[nx-1]

    cdef np.ndarray[np.double_t] q = np.empty(nx, dtype=np.double)
    compute_restricted_inverse(theta, dg, state, pD, q, True)

    cdef int i, j

    for i in range(n):
        for j in range(n):
            g[i, j] = 0

    cdef int state_copy
    cdef double *r_vec = <double *> malloc(nx * sizeof(double))

    cdef double *shuffled_vec
    cdef double *old_vec
    cdef double *swap_vec

    cdef double *ptmp = <double *> malloc(nx * sizeof(double))

    # compute the gradient efficiently using the shuffle trick
    for i in range(n):
        restricted_kronvec(theta, i, pth, state, mutation_num, ptmp, diag=True)
        for j in range(nx):
            r_vec[j] = q[j] * ptmp[j] 
        old_vec = &r_vec[0]
        # reuse the allocated memory of ptmp for the shuffle since the entries of ptmp are no longer used anyway
        shuffled_vec = ptmp
        state_copy = state[0].parts[0]
        for j in range(n):
            if state_copy & 1:
                # shuffle entries of old_vec
                dcopy(&nxhalf, old_vec, &incx2, shuffled_vec, &incx)
                dcopy(&nxhalf, old_vec+1, &incx2, shuffled_vec+nxhalf, &incx)
                # add up the entries of the second half of the shuffled vector to get the partial derivative
                g[i, j] = ddot(&nxhalf, shuffled_vec+nxhalf, &incx, &one, &incx0)
                # in the case i == j also add all the entries of the first half of the shuffled vector
                if i == j:
                    g[i, j] += ddot(&nxhalf, shuffled_vec, &incx, &one, &incx0)

                # make shuffled_vec the old_vec and vice versa for the next iteration
                swap_vec = old_vec
                old_vec = shuffled_vec
                shuffled_vec = swap_vec

            elif i == j:
                # add up all entries of old_vec (respectively r_vec) to get the partial derivative for i == j, if gene i is not mutated
                g[i, j] = ddot(&nx, old_vec, &incx, &one, &incx0)

            # if the mutation state of the next gene is stored on the current state_copy, make a bit shift to the right
            # else state_copy becomes the next integer stored in the given state (x >> 5  <=> x // 32, x & 31 <=> x % 32)
            if (j + 1) & 31:
                state_copy >>= 1
            else:
                state_copy = state[0].parts[(j+1) >> 5]

    free(ptmp)
    free(r_vec)
    free(dg)

    return log(pth[nx - 1])


cpdef cython_gradient_and_score(double[:, :] theta, StateStorage mutation_data):
    """
    Computes the total gradient and score for a given MHN and given mutation data

    :param theta: matrix containing the theta entries of the current MHN
    :param mutation_data: StateStorage containing the mutation data the MHN should be trained on
    :return: tuple containing the gradient and the score
    """
    cdef int n = theta.shape[0]
    cdef int data_size = mutation_data.data_size
    cdef int i, j
    cdef np.ndarray[np.double_t, ndim=2] final_gradient = np.zeros((n, n), dtype=np.double)
    cdef double *local_grad_sum
    cdef np.ndarray[np.double_t, ndim=2] local_gradient_container = np.empty((n, n), dtype=np.double)
    cdef double zero = 0
    cdef int incx = 1
    cdef double one = 1
    cdef int n_square = n*n

    cdef double score = 0

    for i in range(data_size):
        # for each sample/patient in mutation_data,
        # compute the gradient and score for the sample and add them to the total gradient and total score
        score += restricted_gradient_and_score(theta, &mutation_data.states[i], local_gradient_container)
        final_gradient += local_gradient_container

    # return the normalized gradient and normalized score
    return (final_gradient / data_size), (score / data_size)


# this function is only defined if the CUDA-compiler (nvcc) is available on your device
IF NVCC_AVAILABLE:
    class CUDAError(Exception):
        """
        Error raised if something went wrong during execution of the CUDA code
        """

    cpdef cuda_gradient_and_score(double[:, :] theta, StateStorage mutation_data):
        """
        This function is a wrapper for the cuda implementation of the state space restriction

        :param theta: matrix containing the theta entries of the current MHN
        :param mutation_data: StateStorage containing the mutation data the MHN should be trained on
        :return: tuple containing the normalized gradient and score
        """

        cdef int n = theta.shape[0]
        cdef int data_size = mutation_data.data_size

        cdef double score
        cdef np.ndarray[np.double_t] grad_out = np.empty(n * n, dtype=np.double)
        cdef int error_code
        cdef const char *error_name
        cdef const char *error_description

        error_code = cuda_gradient_and_score_implementation(&theta[0, 0], n, &mutation_data.states[0], data_size, &grad_out[0], &score)

        if error_code != 0:
            get_error_name_and_description(error_code, &error_name, &error_description)
            raise CUDAError(f'{error_name.decode("UTF-8")}: "{error_description.decode("UTF-8")}"')

        return (grad_out.reshape((n, n)) / data_size), (score / data_size)


cpdef gradient_and_score(double[:, :] theta, StateStorage mutation_data):
    """
    If CUDA is available, this function will use the CUDA implementation, if the maximum number of mutations
    in a single sample in the data exceeds 12, else it will use the Cython implementation.
    If CUDA is not available on your device, this function will always use the Cython implementation.
    """
    IF NVCC_AVAILABLE:
        if mutation_data.get_max_mutation_num() > 12:
            return cuda_gradient_and_score(theta, mutation_data)
        else:
            return cython_gradient_and_score(theta, mutation_data)
    ELSE:
        return cython_gradient_and_score(theta, mutation_data)


CUDA_AVAILABLE = "CUDA is available"
CUDA_NOT_AVAILABLE = "The CUDA compiler nvcc could not be found"
CUDA_NOT_FUNCTIONAL = "CUDA compiler nvcc available but CUDA functions not working. Check CUDA installation"
def cuda_available():
    """
    Call this function if you want to know if the mhn package is able to use CUDA functions on your device.
    """
    IF NVCC_AVAILABLE:
        if cuda_functional():
            return CUDA_AVAILABLE
        else:
            return CUDA_NOT_FUNCTIONAL
    ELSE:
        return CUDA_NOT_AVAILABLE

