# by Stefan Vocht
#
# this cython file contains functions and classes to store and convert mutation states
#

from libc.stdlib cimport malloc, free

from mhn.ssr.state_storage cimport State

import numpy as np
import warnings

# STATE_SIZE is defined in setup.py, 
# the maximum number n of genes the MHN can handle is 32 * STATE_SIZE


cdef int compute_max_mutation_number(int[:, :] mutation_data):
    """
    This function is used to compute the maximum number of mutations in a single sample of the data
    """
    cdef int max_mutation_num = 0
    cdef int local_sum
    cdef int i, j
    for i in range(mutation_data.shape[0]):
        local_sum = 0
        for j in range(mutation_data.shape[1]):
            local_sum += mutation_data[i, j]

        if local_sum > max_mutation_num:
            max_mutation_num = local_sum

    return max_mutation_num


cdef void fill_states(State *states, int[:, :] mutation_data):
    """
    This function fills the given (yet empty) states with the information from mutation_data
    """
    cdef int i, j
    cdef State *current_state
    cdef int gene_num = mutation_data.shape[1]

    for i in range(mutation_data.shape[0]):
        current_state = states + i

        for j in range(STATE_SIZE):
            current_state[0].parts[j] = 0

        for j in range(gene_num):
            if mutation_data[i, j]:
                current_state[0].parts[j >> 5] |=  1 << (j & 31)


cdef class StateStorage:
    """
    This class is used as a wrapper such that the C array containing the States can be referenced in a Python script
    It also makes sure that there aren't more than 32 mutations present in a single sample as this would break the algorithms
    """

    def __cinit__(self, int[:, :] mutation_data):

        # the number of columns (number of genes) must not exceed 32 * STATE_SIZE
        if mutation_data.shape[1] > (32 * STATE_SIZE):
            raise ValueError(f"The number of genes present in the mutation data must not exceed {32 * STATE_SIZE}")

        self.data_size = mutation_data.shape[0]
        self.gene_num = mutation_data.shape[1]

        self.max_mutation_num = compute_max_mutation_number(mutation_data)
        if self.max_mutation_num == 0:
            warnings.warn("Your data does not contain any mutations, something went probably wrong")
        elif self.max_mutation_num > 32:
            raise ValueError("A single sample must not contain more than 32 mutations")

        self.states = <State *> malloc(self.data_size * sizeof(State))

        if not self.states:
            raise MemoryError()

        fill_states(self.states, mutation_data)


    def get_data_shape(self):
        """
        returns a tuple containing the number of tumor samples and the number of genes stored in this object
        """
        return (self.data_size, self.gene_num)

    def get_max_mutation_num(self):
        """
        returns the maximum number of mutations present in a single sample, might be useful as a sanity check
        """
        return self.max_mutation_num

    def __dealloc__(self):
        free(self.states)


def create_indep_model(StateStorage state_storage):
    """
    Compute an independence model from the data stored in the StateStorage object
    """

    cdef int n = state_storage.gene_num

    cdef int i, j
    cdef int sum_of_occurance

    theta = np.zeros((n, n))

    for i in range(n):
        sum_of_occurance = 0
        for j in range(state_storage.data_size):
            sum_of_occurance += (state_storage.states[j].parts[i >> 5] >> (i & 31)) & 1

        theta[i, i] = np.log(sum_of_occurance / (state_storage.data_size - sum_of_occurance + 1e-10))

    return np.around(theta, decimals=2)