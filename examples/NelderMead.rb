require 'MixedModels'

require 'distribution'
rand_norm = Distribution::Normal.rng(0,1)

# Generate the 5000x2 fixed effects design matrix
x_array = Array.new(10000) { 1 }
x_array.each_index { |i| x_array[i]=(i+1)/2 if (i+1)%2==0 } 
x = NMatrix.new([5000,2], x_array, dtype: :float64)

# Fixed effects coefficient vector
beta = NMatrix.new([2,1], [2,3], dtype: :float64)

# Generate the mixed effects model matrix
# (Assume a group structure with five groups of equal size)
grp_mat = NMatrix.zeros([5000,5], dtype: :float64)
[0,1000,2000,3000,4000].each { |i| grp_mat[i...(i+1000), i/1000] = 1.0 }
# (Create matrix for random intercept and slope)
z = grp_mat.khatri_rao_rows x

# Generate the random effects vector 
# Values generated by R from the multivariate distribution with mean 0
# and covariance matrix [ [1, 0.5], [0.5, 1] ]
b_array = [ -1.34291864, 0.37214635,-0.42979766, 0.03111855, 1.98241161, 
            0.71735038, 0.40448848,-0.28236437, 0.33479745,-0.11086452 ]
b = NMatrix.new([10,1], b_array, dtype: :float64)

# Generate the random residuals vector
# Values generated from the standard Normal distribution
epsilon_array = Array.new(5000) { rand_norm.call } 
epsilon = NMatrix.new([5000,1], epsilon_array, dtype: :float64)
 
# Generate the response vector
y = (x.dot beta) + (z.dot b) + epsilon

# Set up the random effects covariance parameters
lambdat = NMatrix.identity(10, dtype: :float64)

# Set up an LMMData object
model_data = LMMData.new(x: x, y: y, zt: z.transpose, lambdat: lambdat) do |th| 
  diag_blocks = Array.new(5) { NMatrix.new([2,2], [th[0],th[1],0,th[2]], dtype: :float64) }
  NMatrix.block_diagonal(*diag_blocks, dtype: :float64) 
end

# Set up the deviance function
dev_fun = MixedModels::mk_lmm_dev_fun(model_data, false)
reml_fun = MixedModels::mk_lmm_dev_fun(model_data, true)

# Optimize the deviance
min_dev_fun = MixedModels::NelderMead.minimize(start_point: [1,0,1], lower_bound: Array[0,-Float::INFINITY,0], &dev_fun)
puts "beta estimate after deviance minimization: #{model_data.beta}"
min_reml_fun = MixedModels::NelderMead.minimize(start_point: Array[1,0,1], lower_bound: Array[0,-Float::INFINITY,0], &reml_fun)
puts "beta estimate after REML minimization: #{model_data.beta}"

puts "Minimum deviance = #{min_dev_fun.f_minimum}"
puts "Minimum deviance at theta = #{min_dev_fun.x_minimum}"
puts "Minimum REML criterion = #{min_reml_fun.f_minimum}"
puts "Minimum REML criterion at theta = #{min_reml_fun.x_minimum}"

