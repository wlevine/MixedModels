require 'MixedModels'

##############################################################################
# Model with numerical and categorical variables as fixed and random effects # 
##############################################################################

#shouldn't use absolute path here:
df = Daru::DataFrame.from_csv '/home/alexej/github/MixedModels/examples/data/alien_species.csv'

model_fit = LMM.from_formula(formula: "Aggression ~ Age + Species + (Age | Location)", data: df)
 
# Print some results
puts "REML criterion: \t#{model_fit.dev_optimal}"
puts "Fixed effects:"
puts model_fit.fix_ef
puts "Standard deviation: \t#{Math::sqrt(model_fit.sigma2)}"
