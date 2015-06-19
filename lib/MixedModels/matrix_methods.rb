require 'nmatrix'

class NMatrix

  # Compute the the Kronecker product of two row vectors (NMatrix of shape [1,n])
  #
  # === Arguments
  #
  #   * +v+ - A NMatrix of shape [1,n] (i.e. a row vector)
  #
  # === Usage 
  #
  #  a = NMatrix.new([1,3], [0,1,0])
  #  b = NMatrix.new([1,2], [3,2])
  #  a.kron_prod_1D b #  =>  [ [0, 0, 3, 2, 0, 0] ]
  #  
  def kron_prod_1D(v)
    #use && instead of and: http://devblog.avdi.org/2010/08/02/using-and-and-or-in-ruby/
    unless self.dimensions==2 and v.dimensions==2 and self.shape[0]==1 and v.shape[0]==1
      raise ArgumentError, "Implemented for NMatrix of shape [1,n] (i.e. one row) only."
    end
    #TODO: maybe some outer product function from LAPACK would be more efficient to compute for m
    #We don't have anything like this from LAPACK implemented currently in nmatrix. If you want
    #something, let us know.
    m = self.transpose.dot v
    l = self.shape[1]*v.shape[1]
    return m.reshape([1,l])
  end

  # Compute a simplified version of the Khatri-Rao product of +self+ and other NMatrix +mat+.
  # The i'th row of the resulting matrix is the Kronecker product of the i'th row of +self+
  # and the i'th row of +mat+.
  #
  # === Arguments
  #
  # * +mat+ - A 2D NMatrix object
  #
  # === Usage
  #
  # a = NMatrix.new([3,2], [1,2,1,2,1,2], dtype: dtype, stype: stype)
  # b = NMatrix.new([3,2], (1..6).to_a, dtype: dtype, stype: stype)
  # Your b below should have brackets between rows:
  # m = a.khatri_rao_rows b # =>  [ [1.0, 2.0,  2.0,  4.0,
  #                                  3.0, 4.0,  6.0,  8.0,
  #                                  5.0, 6.0, 10.0, 12.0] ]
  #
  def khatri_rao_rows(mat)
    raise NotImplementedError, "Implemented for 2D matrices only" unless self.dimensions==2 and mat.dimensions==2
    n = self.shape[0]
    raise NotImplementedError, "Both matrices must have the same number of rows" unless n==mat.shape[0]
    m = self.shape[1]*mat.shape[1]
    #should use NMatrix::upcast(dtype1,dtype2) to find the proper dtype for the product:
    khrao_prod = NMatrix.new([n,m], dtype: :float64)
    (0...n).each do |i|
      #don't use such similar variable names
      kr_prod = self.row(i).kron_prod_1D mat.row(i)
      khrao_prod[i,0...m] = kr_prod
    end
    return khrao_prod
  end

  # Solve a matrix-valued linear system A * X = B, where A is a nxn matrix, B and X are nxp matrices.
  #
  # === Arguments
  #
  # * +rhs_mat+ - the 2D matrix on the right hand side of the linear system
  #
  # === Usage
  #
  # a = NMatrix.random([10,10], dtype: :float64)
  # b = NMatrix.random([10,5], dtype: :float64)
  # x = a.solve(b)
  #
  def matrix_valued_solve(rhs_mat)
    #add a comment about this workaroudn, or a link to the nmatrix issue
    rhs_mat_t = rhs_mat.transpose
    lhs_mat = self.clone
    NMatrix::LAPACK::clapack_gesv(:row, lhs_mat.shape[0], rhs_mat.shape[1], 
                                  lhs_mat, lhs_mat.shape[0], rhs_mat_t, rhs_mat.shape[0])
    return rhs_mat_t.transpose
  end

  # Solve a linear system A * x = b, where A is a lower triangular matrix, 
  # x and b are vectors. 
  #
  # === Arguments
  #
  # * +uplo+ - flag indicating whether the matrix is lower or upper triangular;
  #            possible values are :lower and :upper
  # * +rhs+  - the right hand side, a nx1 NMatrix object
  #
  # === Usage
  #
  # a = NMatrix.new(3, [4, 0, 0, -2, 2, 0, -4, -2, -0.5], dtype: :float64)
  # b = NMatrix.new([3,1], [-1, 17, -9], dtype: :float64)
  # x = a.triangular_solve(:lower, b)
  # a.dot x # => [ [-1.0]   [17.0]   [-9.0] ]
  #
  def triangular_solve(uplo, rhs)
    raise(ArgumentError, "uplo should be :lower or :upper") unless uplo == :lower or uplo == :upper
    b = rhs.clone
    a = self.clone
    NMatrix::BLAS::cblas_trsm(:row, :right, uplo, :transpose, :nounit, 
                              b.shape[1], b.shape[0], 1.0, a, a.shape[0],
                              b, b.shape[0])
    return b
  end

  class << self

    # Generate a block-diagonal NMatrix from the supplied 2D square matrices.
    #
    # ==== Arguments
    #
    #  * +params+ - An array that collects all arguments passed to the method. The method
    #                can receive any number of arguments. The last entry of +params+ is a 
    #                hash of options from NMatrix#initialize. All other entries of +params+ are 
    #                the blocks of the desired block-diagonal matrix, which are supplied
    #                as square 2D NMatrix objects.
    #
    # ==== Usage
    #
    #  a = NMatrix.new([2,2],[1,2,3,4])
    #  b = NMatrix.new([1,1],[123],dtype: :int32)
    #  c = NMatrix.new([3,3],[1,2,3,1,2,3,1,2,3], dtype: :float64)
    #  m = NMatrix.block_diagonal(a,b,c,dtype: :int64, stype: :yale)
    #      => 
    #      [
    #        [1, 2,   0, 0, 0, 0]
    #        [3, 4,   0, 0, 0, 0]
    #        [0, 0, 123, 0, 0, 0]
    #        [0, 0,   0, 1, 2, 3]
    #        [0, 0,   0, 1, 2, 3]
    #        [0, 0,   0, 1, 2, 3]
    #      ]
    #
    def block_diagonal(*params)
      options = params.last.is_a?(Hash) ? params.pop : {}

      block_sizes = [] #holds the size of each matrix block
      params.each do |b|
        raise ArgumentError, "Only NMatrix objects allowed" unless b.is_a?(NMatrix)
        raise ArgumentError, "Only 2D matrices allowed" unless b.shape.size == 2
        raise ArgumentError, "Only square matrices allowed" unless b.shape[0] == b.shape[1]
        block_sizes << b.shape[0]
      end

      bdiag = NMatrix.zeros(block_sizes.sum, options)
      (0...params.length).each do |n|
        # First determine the size and position of the n'th block in the block-diagonal matrix
        k = block_sizes[n]
        block_pos = block_sizes[0...n].sum
        # populate the n'th block in the block-diagonal matrix
        #can you do this with a slice assignment?
        #bdiag[block_pos...block_pos+k,block_pos...block_pos+k] = params[n]
        (0...k).each do |i| #or you can say k.times do |i|
          (0...k).each do |j|
            bdiag[block_pos+i,block_pos+j] = params[n][i,j]
          end
        end
      end

      return bdiag
    end

  end
end
