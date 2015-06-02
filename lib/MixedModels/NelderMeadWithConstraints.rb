# Original implementation Copyright (c) 2010 Claudio Bustos
# Modification Copyright (c) 2015 Alexej Gossmann 
#
# Nelder Mead Algorithm for Multidimensional minimization with box constraints
#
# This code was ported from the Ruby gem Minimization,
# available from https://github.com/clbustos/minimization.git
#
# The original Ruby implementation of this algorith was adopted and ported
# into Ruby from Apache-commons Math library's NelderMead.java file. Therefore 
# this file is under Apache License Version 2.
#

module MixedModels

  # class which holds the point,value pair
  class PointValuePair
    attr_accessor :value
    attr_reader   :point

    # == Parameters:
    # * <tt>point</tt>: Coordinates of the point
    # * <tt>value</tt>: Function value at the point
    #
    def initialize(point, value)
      @point = point.clone
      @value  = value
    end

    # returns a copy of the point
    def get_point_clone
      return @point.clone
    end
  end

  # = Nelder Mead Minimizer.
  # A multidimensional minimization methods.
  # == Usage.
  #  min=MixedModels::NelderMead.new(proc {|x| (x[0] - 2)**2 + (x[1] - 5)**2}, [1, 2])
  #  while min.converging?
  #    min.iterate
  #  end
  #  min.x_minimum
  #  min.f_minimum
  #
  class NelderMead

    EPSILON_DEFAULT         = 1e-6
    MAX_ITERATIONS_DEFAULT  = 1000000

    attr_reader :x_minimum, :f_minimum, :epsilon, :max_iterations

    def initialize(start_point:, lower_bound: nil, upper_bound: nil, &f)
      # Reflection coefficient
      @rho   = 1.0
      # Expansion coefficient
      @khi   = 2.0
      # Contraction coefficient
      @gamma = 0.5
      # Shrinkage coefficient
      @sigma = 0.5

      @epsilon             = EPSILON_DEFAULT
      # Default number of maximum iterations
      @max_iterations      = MAX_ITERATIONS_DEFAULT
      @relative_threshold  = 100 * @epsilon
      @absolute_threshold  = @epsilon
      @x_minimum           = nil
      @f_minimum           = nil
      @f                   = f

      n = start_point.length
      # create and initialize start configurations
      if @start_configuration == nil
        # sets the start configuration point as unit
        self.start_configuration = Array.new(n) { 1.0 }
      end

      if lower_bound.nil? then
        lower_bound = Array.new(n) { -Float::INFINITY }
      else
        raise "Lower bound should be of the same length as the start point" unless lower_bound.length == n
        @lower_bound = lower_bound 
      end
      if upper_bound.nil? then
        upper_bound = Array.new(n) { Float::INFINITY }
      else
        raise "Upper bound should be of the same length as the start point" unless upper_bound.length == n
        @upper_bound = upper_bound 
      end
      0.upto(n-1) do
        raise "Lower bounds should be smaller than upper bounds" unless lower_bound[i] < upper_bound[i]
      end

      @iterations  = 0
      @evaluations = 0
      # create the simplex for the first time
      build_simplex(start_point)
      evaluate_simplex
    end

    def f(x)
      return @f.call(x)
    end

    # only the relative position of the n vertices with respect
    # to the first one are stored
    def start_configuration=(steps)
      n = steps.length
      @start_configuration = Array.new(n) { Array.new(n, 0) }
      0.upto(n - 1) do |i|
        vertex_i = @start_configuration[i]
        raise "equals vertices #{i-1} and #{i} in simplex configuration" if steps[i] == 0.0
        0.upto(i) { |j| vertex_i[j] = steps[j] }
      end
    end

    # Check if a given point is within the bounds 
    # given by @lower_bound and @upper_bound, and if that's not the case
    # then move the point inside the bounded region.
    # The returned value is the shifted point if it was necessary to move it
    # (otherwise the originally supplied point).
    # == Parameters:
    # * <tt>point</tt>: an array with the coordinates of the point
    #
    def move_into_bounds(point)
      n = point.length
      raise "dimension mismatch" if n != @start_configuration.length
      0.upto(n-1) do |i|
        point[i] = @lower_bound[i] if @lower_bound[i] > point[i]
        point[i] = @upper_bound[i] if @upper_bound[i] < point[i]
      end
      return point
    end

    # Build an initial simplex
    # == Parameters:
    # * <tt>start_point</tt>: starting point of the minimization search
    #
    def build_simplex(start_point)
      n = start_point.length
      raise "dimension mismatch" if n != @start_configuration.length
      # set first vertex
      @simplex = Array.new(n+1)
      @simplex[0] = PointValuePair.new(move_into_bounds(start_point), Float::NAN)

      # set remaining vertices
      0.upto(n - 1) do |i|
        conf_i   = @start_configuration[i]
        vertex_i = Array.new(n)
        0.upto(n - 1) do |k|
          vertex_i[k] = start_point[k] + conf_i[k]
        end
        @simplex[i + 1] = PointValuePair.new(move_into_bounds(vertex_i), Float::NAN)
      end
    end
    
    # Evaluate all the non-evaluated points of the simplex
    def evaluate_simplex
      # evaluate the objective function at all non-evaluated simplex points
      0.upto(@simplex.length - 1) do |i|
        vertex = @simplex[i]
        point  = vertex.point
        if vertex.value.nan?
          @simplex[i] = PointValuePair.new(point, f(point))
        end
      end
      # sort the simplex from best to worst
      @simplex.sort!{ |x1, x2| x1.value <=> x2.value }
    end

    # checks whether the function is converging.
    # Returns true if not converged yet, false when converged.
    def converging?
      # check the convergence in a given direction comparing the previous and current values
      def point_converged?(previous, current)
        pre        = previous.value
        curr       = current.value
        diff       = (pre - curr).abs
        size       = [pre.abs, curr.abs].max
        return (diff <= (size * @relative_threshold)) and (diff <= @absolute_threshold)
      end

      # returns true if converging is possible atleast in one direction
      if @iterations > 0
        # given direction is converged
        converged = true
        0.upto(@simplex.length - 1) do |i|
          converged &= point_converged?(@previous[i], @simplex[i])
        end
        return !converged
      end

      # if no iterations were done, convergence undefined
      return true
    end

    # increment iteration counter by 1
    def increment_iterations_counter
      @iterations += 1
      raise "iteration limit reached" if @iterations > @max_iterations
    end

    # compares 2 PointValuePair points
    def compare(v1, v2)
      if v1.value == v2.value
        return 0
      elsif v1.value > v2.value
        return 1
      else
        return -1
      end
    end

    # Replace the worst point of the simplex by a new point
    # == Parameters:
    # * <tt>point_value_pair</tt>: point to insert
    #
    def replace_worst_point(point_value_pair)
      n = @simplex.length - 1
      0.upto(n - 1) do |i|
        if (compare(@simplex[i], point_value_pair) > 0)
          point_value_pair, @simplex[i] = @simplex[i], point_value_pair
        end
      end
      @simplex[n] = point_value_pair
    end

    def iterate_simplex
      increment_iterations_counter
      
      # the simplex has n+1 point if dimension is n
      n = @simplex.length - 1
      best        = @simplex[0]
      secondWorst = @simplex[n - 1]
      worst       = @simplex[n]
      x_worst     = worst.point
      
      # compute the centroid of the best vertices
      # (dismissing the worst point at index n)
      centroid   = Array.new(n, 0)
      0.upto(n - 1) do |i|
        x = @simplex[i].point
        0.upto(n - 1) { |j| centroid[j] += x[j] }
      end
      scaling = 1.0 / n
      0.upto(n - 1) { |j| centroid[j] *= scaling }

      # compute the reflection point
      xr = Array.new(n)
      0.upto(n - 1) do |j|
        xr[j] = centroid[j] + @rho * (centroid[j] - x_worst[j])
      end
      xr = move_into_bounds(xr)
      reflected = PointValuePair.new(xr, f(xr))
      if ((compare(best, reflected) <= 0) && (compare(reflected, secondWorst) < 0))
        # accept the reflected point
        replace_worst_point(reflected)
      elsif (compare(reflected, best) < 0)
        # compute the expansion point
        xe = Array.new(n)
        0.upto(n - 1) do |j|
          xe[j] = centroid[j] + @khi * (xr[j] - centroid[j])
        end
        xe = move_into_bounds(xe)
        expanded = PointValuePair.new(xe, f(xe))
        if (compare(expanded, reflected) < 0)
          # accept the expansion point
          replace_worst_point(expanded)
        else
          # accept the reflected point
          replace_worst_point(reflected)
        end
      else
        if (compare(reflected, worst) < 0)
          # perform an outside contraction
          xc = Array.new(n)
          0.upto(n - 1) do |j|
            xc[j] = centroid[j] + @gamma * (xr[j] - centroid[j])
          end
          xc = move_into_bounds(xc)
          out_contracted = PointValuePair.new(xc, f(xc))
          if (compare(out_contracted, reflected) <= 0)
            # accept the contraction point
            replace_worst_point(out_contracted)
            return
          end
        else
          # perform an inside contraction
          xc = Array.new(n)
          0.upto(n - 1) do |j|
            xc[j] = centroid[j] - @gamma * (centroid[j] - x_worst[j])
          end
          xc = move_into_bounds(xc)
          in_contracted = PointValuePair.new(xc, f(xc))

          if (compare(in_contracted, worst) < 0)
            # accept the contraction point
            replace_worst_point(in_contracted)
            return
          end
        end
        # perform a shrink
        x_smallest = @simplex[0].point
        0.upto(@simplex.length - 1) do |i|
          x = @simplex[i].get_point_clone
          0.upto(n - 1) do |j|
            x[j] = x_smallest[j] + @sigma * (x[j] - x_smallest[j])
          end
          @simplex[i] = PointValuePair.new(x, Float::NAN)
        end
        evaluate_simplex
      end
    end

    # Convenience method to minimize
    # == Parameters:
    # * <tt>start_point</tt>: Starting points
    # * <tt>f</tt>: Function to minimize
    # == Usage:
    #   minimizer=MixedModels::NelderMead.minimize(proc{|x| (x[0] - 1) ** 2 + (x[1] - 5) ** 2}, [0, 0])
    #
    def self.minimize(f, start_point)
      min=MixedModels::NelderMead.new(f, start_point)
      while min.converging?
        min.iterate
      end
      return min
    end

    # Iterate the simplex one step. Use this when iteration needs to be done manually
    # == Usage:
    #   minimizer=MixedModels::NelderMead.new(proc{|x| (x[0] - 1) ** 2 + (x[1] - 5) ** 2}, [0, 0])
    #   while minimizer.converging?
    #     minimizer.Iterate
    #   end
    #   minimizer.x_minimum
    #   minimizer.f_minimum
    #
    def iterate
      # set previous simplex as the current simplex
      @previous = Array.new(@simplex.length)
      0.upto(@simplex.length - 1) do |i|
        point = @simplex[i].point                                # clone require?
        @previous[i] = PointValuePair.new(point, f(point))
      end
      # iterate simplex
      iterate_simplex
      # set results
      @x_minimum = @simplex[0].point
      @f_minimum = @simplex[0].value
    end
  end
end