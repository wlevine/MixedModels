# Copyright (c) 2015 Alexej Gossmann 
 
require 'nmatrix'
require 'daru'

# Linear mixed effects models.
# The implementation is based on Bates et al. (2014)
#
# === References
# 
# * Douglas Bates, Martin Maechler, Ben Bolker, Steve Walker, 
#   "Fitting Linear Mixed - Effects Models using lme4". arXiv:1406.5823v1 [stat.CO]. 2014.
#
class LMM

  attr_reader :reml, :theta_optimal, :dev_optimal, :dev_fun, :optimization_result, :model_data,
              :sigma2, :sigma_mat, :fix_ef_cov_mat, :ran_ef_cov_mat, :sse, :fix_ef, :ran_ef

  # Fit and store a linear mixed effects model according to the input from the user.
  # Parameter estimates are obtained by the method described in Bates et. al. (2014).
  #
  # === Arguments
  #
  # * +x+              - fixed effects model matrix as a dense NMatrix
  # * +y+              - response vector as a nx1 dense NMatrix
  # * +zt+             - transpose of the random effects model matrix as a dense NMatrix
  # * +lambdat+        - upper triangular Cholesky factor of the relative 
  #                      covariance matrix of the random effects; a dense NMatrix
  #I still don't get this. lambdat is supposed to be generated as a function of
  #theta, which is an unknown parameter. What does this argument do?
  # * +weights+        - optional Array of prior weights
  # * +offset+         - an optional vector of offset terms which are known 
  #                      a priori; a nx1 NMatrix
  # * +reml+           - if true than the profiled REML criterion will be used as the objective
  #                      function for the minimization; if false then the profiled deviance 
  #                      will be used; defaults to true
  # * +start_point+    - an Array specifying the initial parameter estimates for the 
  #What is the format for this?
  #                      minimization
  # * +lower_bound+    - an optional Array of lower bounds for each coordinate of the optimal 
  #                      solution 
  # * +upper_bound+    - an optional Array of upper bounds for each coordinate of the optimal 
  #                      solution 
  # * +epsilon+        - a small number specifying the thresholds for the convergence check 
  #                      of the optimization algorithm; see the respective documentation for 
  #                      more detail
  # * +max_iterations+ - the maximum number of iterations for the optimization algorithm
  # * +thfun+          - a block or +Proc+ object that takes a value of +theta+ and produces
  #What arguments does thfun expect?
  #
  #                      the non-zero elements of +Lambdat+.  The structure of +Lambdat+
  #Lambdat should be lowercase.
  #                      cannot change, only the numerical values.
  # === References
  # 
  # * Douglas Bates, Martin Maechler, Ben Bolker, Steve Walker, 
  #   "Fitting Linear Mixed - Effects Models using lme4". arXiv:1406.5823v1 [stat.CO]. 2014.
  #
  def initialize(x:, y:, zt:, lambdat:, weights: nil, offset: 0.0, reml: true, 
                 start_point:, lower_bound: nil, upper_bound: nil, epsilon: 1e-6, 
                 max_iterations: 1e6, &thfun)
    @reml = reml

    ################################################
    # Fit the linear mixed model
    ################################################

    # (1) Create the data structure in a LMMData object
    @model_data = LMMData.new(x: x, y: y, zt: zt, lambdat: lambdat, 
                              weights: weights, offset: offset, &thfun)
    
    # (2) Set up the profiled deviance/REML function
    @dev_fun = MixedModels::mk_lmm_dev_fun(@model_data, @reml)

    # (3) Optimize the deviance/REML
    @optimization_result = MixedModels::NelderMead.minimize(start_point: start_point, 
                                                            lower_bound: lower_bound, 
                                                            upper_bound: upper_bound,
                                                            epsilon: epsilon, 
                                                            max_iterations: max_iterations,
                                                            &dev_fun)

    #################################################
    # Compute and store some output parameters
    #################################################
    
    # optimal solution for theta
    @theta_optimal = @optimization_result.x_minimum 
    # function value at the optimal solution
    @dev_optimal   = @optimization_result.f_minimum 

    # sum of squared residuals
    @sse = 0.0
    self.residuals.each { |r| @sse += r**2 }

    # scale parameter of the covariance (the residuals conditional on the random 
    # effects have variances "sigma2*weights^(-1)"; if all weights are ones then 
    # sigma2 is an estimate of the residual variance)
    @sigma2 = if reml then
               @model_data.pwrss / (@model_data.n - @model_data.p)
             else
               @model_data.pwrss / @model_data.n
             end

    # estimate of the covariance matrix Sigma of the random effects vector b,
    # where b ~ N(0, Sigma).
    @sigma_mat = (@model_data.lambdat.transpose.dot @model_data.lambdat) * @sigma2

    # variance-covariance matrix of the random effects estimates, conditional on the
    # input data, as given in equation (58) in Bates et. al. (2014).
    rhs = NMatrix.identity(@model_data.q, dtype: :float64) * sigma2
    u = @model_data.l.triangular_solve(:lower, rhs)
    v = @model_data.l.transpose.triangular_solve(:upper, u)
    @ran_ef_cov_mat = (@model_data.lambdat.transpose.dot v).dot @model_data.lambdat

    # variance-covariance matrix of the fixed effects estimates, conditional on the
    # input data, as given in equation (54) in Bates et. al. (2014).
    @fix_ef_cov_mat = @model_data.rxtrx.inverse * @sigma2

    # Construct a Hash containing information about the estimated fixed effects 
    # coefficiants (these estimates are conditional on the estimated covariance parameters).
    @fix_ef = Hash.new
    fix_ef_names = (0...@model_data.beta.shape[0]).map { |i| "x" + i.to_s }
    fix_ef_names.each_with_index { |name, i| @fix_ef[name] = @model_data.beta[i] }
    # TODO: store more info in fix_ef, such as p-values on 95%CI
    
    # Construct a Hash containing information about the estimated mean values of the 
    # random effects (these are conditional estimates which depend on the input data).
    @ran_ef = Hash.new
    ran_ef_names = (0...@model_data.b.shape[0]).map { |i| "z" + i.to_s }
    ran_ef_names.each_with_index { |name, i| @ran_ef[name] = @model_data.b[i] }
    # TODO: store more info in ran_ef, such as p-values on 95%CI
  end

  # Fit and store a linear mixed effects model, specified using a formula interface,
  # from data supplied as Daru::DataFrame. Parameter estimates are obtained via 
  # LMM#from_daru and LMM#initialize.
  #
  # The response variable, fixed effects and random effects are specified with a formula,
  # which uses a smaller version of the laguage of the formula interface to the R package lme4. 
  # Compared to lme4 the formula language here is somewhat restricted by not allowing the use
  # of operators "*" and "||" (equivalent formula formulations are always possible in
  # those cases, using only "+", ":" and "|"). Moreover, nested random effects and the 
  # corresponding operator "/" are not supported. Much detail on formula definitions 
  # can be found in the documentation, papers and tutorials to lme4.
  #
  # === Arguments
  #
  # * +formula+        - a String containing a two-sided linear formula describing both, the 
  #                      fixed effects and random effects of the model, with the response on 
  #                      the left of a ~ operator and the terms, separated by + operators, 
  #                      on the right hand side. Random effects specifications are in 
  #                      parentheses () and contain a vertical bar |. Expressions for design 
  #                      matrices are on the left of the vertical bar |, and grouping factors 
  #                      are on the right. 
  # * +data+           - a Daru::DataFrame object, containing the response, fixed and random 
  #                      effects, as well as the grouping variables
  #Maybe the following parameters which appear in all three of these functions should
  #be encapsulated in a FitOptions class. On the hand, maybe not.
  # * +weights+        - optional Array of prior weights
  # * +offset+         - an optional vector of offset terms which are known 
  #                      a priori; a nx1 NMatrix
  # * +reml+           - if true than the profiled REML criterion will be used as the objective
  #                      function for the minimization; if false then the profiled deviance 
  #                      will be used; defaults to true
  # * +start_point+    - an optional Array specifying the initial parameter estimates for the 
  #                      minimization
  # * +epsilon+        - an optional  small number specifying the thresholds for the 
  #                      convergence check of the optimization algorithm; see the respective 
  #                      documentation for more detail
  # * +max_iterations+ - optional, the maximum number of iterations for the optimization 
  #                      algorithm
  #
  def LMM.from_formula(formula:, data:, weights: nil, offset: 0.0, reml: true, 
                       start_point: nil, epsilon: 1e-6, max_iterations: 1e6)
    #Just out of curiousity, why don't you support the * and ||? Are you planning
    #to implement them later? I'm not blaming you if you skipped them to keep
    #the parser simpler, I'm just curious.
    #
    #You probably want to separate out the formula parser into a separate function
    #so that you could test it independent of providing a dataset. On a related
    #note, it would be nice to have some specs for the parser to make sure
    #it handles all the edge cases.
    #Also, with the parser separate, someone else could implement a different fitter
    #that didn't use daru.
    raise(ArgumentError, "formula must be supplied as a String") unless formula.is_a? String
    raise(NotImplementedError, "The operator * is not supported in formula formulations." +
          "Use the operators + and : instead (e.g. a*b is equivalent to a+b+a:b)") if formula.include? "*"
    raise(NotImplementedError, "Nested random effects are not supported in formula formulation." +
          "The model can still be fit by adding a new column representing the nested grouping structure" +
          "to the data frame.") if formula.include? "/"
    raise(NotImplementedError, "The operator || is not supported in formula formulations." +
          "Reformulate the formula using single vertical lines | instead" +
          "(e.g. (Days || Subj) is equivalent to (1 | Subj) + (0 + Days | Subj))") if formula.include? "||"
    raise(NotImplementedError, "The notation -1 in not supported." +
          "Use 0 instead, in order to denote the exclusion of an intercept term.") if formula.include? "-1"
    #Other ways you could validate input: Does it contains a "~"?
    #Does it contain exactly one "~"? Are the rhs and lhs both non-empty?
    #Are parentheses matched?
    #Probably you also can't have a variable named intercept?

    #remove whitespaces
    formula.gsub!(%r{\s+}, "")
    # replace ":" with "*", because the LMMFormula class requires this convention
    formula.gsub!(":", "*")
    # deal with the intercept (LMM#from_daru handles the case when both, intercept and 
    # no_intercept, are included)
    #It took me a while to figure out these 4 lines. Maybe add some comments.
    #1+ is equivalent to intercept+
    #The 1 is optional when specifying the formula?
    formula.gsub!("~", "~intercept+")
    formula.gsub!("(", "(intercept+")
    formula.gsub!("+1", "")
    formula.gsub!("+0", "+no_intercept")
    # extract the response and right hand side
    split = formula.split "~"
    response = split[0].strip.to_sym
    rhs = split[1] 
    # get all variable names from rhs
    vars = rhs.split %r{\s*[+|()*]\s*}
    vars.delete("")
    vars.uniq!

    #Do you want to impose any constraints on variable names? Are they allowed
    #to start with numbers or contain symbols like "}"?

    # In the String rhs, wrap each variable name "foo" in "MixedModels::lmm_variable(:foo)":
    # Put whitespaces around symbols "+", "|", "*", "(" and ")", and then
    # substitute "name" with "MixedModels::lmm_variable(name)" only if it is surrounded by white 
    # spaces; this trick is used to ensure that for example the variable "a" is not found within 
    # the variable "year"
    #I suspect there's a way to do this whole procedure with just one gsub and a clever regex, but maybe your procedure is clearer

    #there should be a one-liner for this, something like?
    #rhs.gsub!(/([+*|()])/, ' \1 ')
    rhs.gsub!("+", " + ")
    rhs.gsub!("*", " * ")
    rhs.gsub!("|", " | ")
    rhs.gsub!("(", " ( ")
    rhs.gsub!(")", " ) ")

    #use string interpolation: rhs = " #{rhs} "
    rhs = " " + rhs + " "

    #trying to construct a symbol just by adding a ":" will cause trouble if name isn't
    #well-behaved (for example, if it starts with a number)
    #maybe use:
    #name.to_sym.inspect
    vars.each { |name| rhs.gsub!(" " + name + " ", "MixedModels::lmm_variable(:" + name + ")") } 
    # generate an LMMFormula
    rhs_lmm_formula = eval(rhs)
    #fit the model
    rhs_input = rhs_lmm_formula.to_input_for_lmm_from_daru
    model = LMM.from_daru(response: response, 
                          fixed_effects: rhs_input[:fixed_effects],
                          random_effects: rhs_input[:random_effects], 
                          grouping: rhs_input[:grouping],
                          data: data, 
                          weights: weights, offset: offset, reml: reml, 
                          start_point: start_point, epsilon: epsilon, 
                          max_iterations: max_iterations)
    return model
    #I was going to comment that it's the "Ruby way" to avoid explicit `return`
    #when possible. But apparently (http://stackoverflow.com/questions/1023146/is-it-good-style-to-explicitly-return-in-ruby)
    #that's not really true, and besides it's your project so you should use
    #whatever style you want. But either way, you can just say return
    #LMM.from_daru(...), rather than defining model
  end

  # Fit and store a linear mixed effects model from data supplied as Daru::DataFrame.
  # Parameter estimates are obtained via LMM#initialize.
  #
  # The fixed effects are specified as an Array of Symbols (for the respective vectors in
  # the data frame).
  # The random effects are specified as an Array of Arrays, where the variables in each
  # sub-Array correspond to a common grouping factor (given in the Array +grouping+) and are 
  # modeled as correlated.
  #Since elements of random_effects correspond to elements of grouping, maybe you
  #could combine these two together with a hash or small utility class?
  # For both, fixed and random effects, +:intercept+ can be used to denote an intercept term; and 
  # +:no_intercept+ denotes the exclusion of an intercept term, even if +:intercept+ is given. 
  # An interaction effect can be included as an Array of length two, containing the 
  # respective variable names. 
  #
  # All non-numeric vectors in the data frame are considered to be categorical variables
  # and treated accordingly.
  #
  # Nested random effects are currently not supported by this interface.
  #
  # === Arguments
  #
  # * +response+       - name of the response variable in +data+
  # * +fixed_effects+  - names of the fixed effects in +data+, given as an Array. An 
  #                      interaction effect can be specified as Array of length two.
  #                      An intercept term can be denoted as +:intercept+; and 
  #                      +:no_intercept+ denotes the exclusion of an intercept term, even 
  #                      if +:intercept+ is given.
  # * +random_effects+ - names of the random effects in +data+, given as an Array of Arrays;
  #                      where the variables in each (inner) Array share a common grouping 
  #                      structure, and the corresponding random effects are modeled as 
  #                      correlated. An interaction effect can be specified as Array of 
  #                      length two. An intercept term can be denoted as +:intercept+; and 
  #                      +:no_intercept+ denotes the exclusion of an intercept term, even 
  #                      if +:intercept+ is given.
  # * +grouping+       - an Array of the names of the variables in +data+, which determine the
  #                      grouping structures for +random_effects+
  # * +data+           - a Daru::DataFrame object, containing the response, fixed and random 
  #                      effects, as well as the grouping variables
  # * +weights+        - optional Array of prior weights
  # * +offset+         - an optional vector of offset terms which are known 
  #                      a priori; a nx1 NMatrix
  # * +reml+           - if true than the profiled REML criterion will be used as the objective
  #                      function for the minimization; if false then the profiled deviance 
  #                      will be used; defaults to true
  # * +start_point+    - an optional Array specifying the initial parameter estimates for the 
  #                      minimization
  # * +epsilon+        - an optional  small number specifying the thresholds for the 
  #                      convergence check of the optimization algorithm; see the respective 
  #                      documentation for more detail
  # * +max_iterations+ - optional, the maximum number of iterations for the optimization 
  #                      algorithm
  #
  def LMM.from_daru(response:, fixed_effects:, random_effects:, grouping:, data:,
                    weights: nil, offset: 0.0, reml: true, start_point: nil,
                    epsilon: 1e-6, max_iterations: 1e6)
    raise(ArgumentError, "data should be a Daru::DataFrame") unless data.is_a?(Daru::DataFrame)

    n = data.size

    # response vector
    y = NMatrix.new([n,1], data[response].to_a, dtype: :float64)

    # deal with the intercept
    if fixed_effects.include? :no_intercept then
      fixed_effects.delete(:intercept)
      fixed_effects.delete(:no_intercept)
    end
    random_effects.each do |ran_ef|
      if ran_ef.include? :no_intercept then
        ran_ef.delete(:intercept)
        ran_ef.delete(:no_intercept)
      end
    end

    # deal with categorical (non-numeric) variables
    if fixed_effects.include? :intercept then
      no_intercept = false 
    else
      no_intercept = true
    end
    # FIXME: Currently the situation, where fixed effects have an intercept but random effects don't, 
    # is not resolved correctly, because we check only for the fixed effects if they include an intercept term
    new_names = data.create_indicator_vectors_for_categorical_vectors!(for_model_without_intercept: no_intercept)
    categorical_names = new_names.keys
    categorical_names.each do |name|
      # replace the categorical variable name in (non-interaction) fixed_effects
      ind = fixed_effects.find_index(name)
      fixed_effects[ind..ind] = new_names[name] unless ind.nil?
      # replace the categorical variable name in (non-interaction) random_effects 
      random_effects.each_index do |i|
        ind = random_effects[i].find_index(name)
        #?:
        random_effects[i][ind..ind] = new_names[name] unless ind.nil?
      end
    end

    # deal with interaction effects and nested grouping factors
    interaction_names = Array.new
    fixed_effects.each_with_index do |ef, ind|
      if ef.is_a? Array then
        raise(NotImplementedError, "interaction effects can only be bi-variate") unless ef.length == 2
        if categorical_names.include? ef[0] then
          #TODO: implement this!
          raise(NotImplementedError, "interaction effects cannot be categorical") 
        else
          if categorical_names.include? ef[1] then
            #TODO: implement this!
            raise(NotImplementedError, "interaction effects cannot be categorical") 
          else
            inter_name = (ef[0].to_s + "_and_" + ef[1].to_s).to_sym
            unless interaction_names.include? inter_name
              data[inter_name] = data[ef[0]] * data[ef[1]] 
              interaction_names.push(inter_name)
            end
            fixed_effects[ind] = inter_name
          end
        end
      end
    end
    random_effects.each do |ran_ef|
      ran_ef.each_with_index do |ef, ind|
        if ef.is_a? Array then
          raise(NotImplementedError, "interaction effects can only be bi-variate") unless ef.length == 2
          if categorical_names.include? ef[0] then
            #TODO: implement this!
            raise(NotImplementedError, "interaction effects cannot be categorical") 
          else
            if categorical_names.include? ef[1] then
              #TODO: implement this!
              raise(NotImplementedError, "interaction effects cannot be categorical") 
            else
              inter_name = (ef[0].to_s + "_and_" + ef[1].to_s).to_sym
              unless interaction_names.include? inter_name
                data[inter_name] = data[ef[0]] * data[ef[1]]
                interaction_names.push(inter_name)
              end
              ran_ef[ind] = inter_name
            end
          end
        end
      end
    end
    grouping.each_with_index do |grp, ind|
      if grp.is_a? Array then
        #TODO: implement this!
        raise(NotImplementedError, "nested effects not implemented yet")
      end
    end
    
    # add an intercept column, so the intercept will be used whenever specified
    data[:intercept] = Array.new(n) {1.0}

    # construct the fixed effects design matrix
    x_frame = data[*fixed_effects]
    x = x_frame.to_nm

    # construct the random effects model matrix and covariance function 
    num_groups = grouping.length
    raise(ArgumentError, "Length of +random_effects+ mismatches length of +grouping+") unless random_effects.length == num_groups
    ran_ef_raw_mat = Array.new
    ran_ef_grp     = Array.new
    num_ran_ef     = Array.new
    num_grp_levels = Array.new
    0.upto(num_groups-1) do |i|
      xi_frame = data[*random_effects[i]]
      ran_ef_raw_mat[i] = xi_frame.to_nm
      ran_ef_grp[i] = data[grouping[i]].to_a
      num_ran_ef[i] = ran_ef_raw_mat[i].shape[1]
      num_grp_levels[i] = ran_ef_grp[i].uniq.length
    end
    z     = MixedModels::mk_ran_ef_model_matrix(ran_ef_raw_mat, ran_ef_grp)
    thfun = MixedModels::mk_ran_ef_cov_fun(num_ran_ef, num_grp_levels)

    # define the starting point for the optimization (if it's nil),
    # such that random effects are independent with variances equal to one
    q = num_ran_ef.sum
    if start_point.nil? then
      tmp1 = Array.new(q) {1.0}
      tmp2 = Array.new(q*(q-1)/2) {0.0}
      start_point = tmp1 + tmp2
    end
    lambdat = thfun.call(start_point)

    # set the lower bound on the variance-covariance parameters
    tmp1 = Array.new(q) {0.0}
    tmp2 = Array.new(q*(q-1)/2) {-Float::INFINITY}
    lower_bound = tmp1 + tmp2

    # fit the model
    lmmfit = LMM.new(x: x, y: y, zt: z.transpose, lambdat: lambdat, 
                     weights: weights, offset: offset, 
                     reml: reml, start_point: start_point, 
                     lower_bound: lower_bound, epsilon: epsilon, 
                     max_iterations: max_iterations, &thfun)
    return lmmfit
  end

  # An Array containing the fitted response values, i.e. the estimated mean of the response
  # (conditional on the estimates of the covariance parameters, the random effects,
  # and the fixed effects).
  def fitted
    @model_data.mu.to_flat_a
  end

  # An Array containing the model residuals, which are defined as the difference between the
  # response and the fitted values.
  #
  def residuals
    (@model_data.y - @model_data.mu).to_flat_a
  end
end
