Random.seed!(1)

function computeSecondOrderModel(f::Float64, g::Vector{Float64}, H, d_k::Vector{Float64})
    return transpose(g) * d_k + 0.5 * transpose(d_k) * H * d_k
end

function compute_ρ_hat(fval_current::Float64, fval_next::Float64, gval_current::Vector{Float64}, gval_next::Vector{Float64}, H, d_k::Vector{Float64}, θ::Float64, min_gval_norm::Float64, print_level::Int64=0, approach::String="DEFAULT")
    second_order_model_value_current_iterate = computeSecondOrderModel(fval_current,  gval_current, H, d_k)
	guarantee_factor = θ * 0.5 * min(norm(gval_current, 2), norm(gval_next, 2)) * norm(d_k, 2)
	if approach != "DEFAULT"
		# guarantee_factor = θ * 0.5 * norm(gval_next, 2) * norm(d_k, 2)
		guarantee_factor = 0.0
	end
	actual_fct_decrease = fval_current - fval_next
	predicted_fct_decrease = - second_order_model_value_current_iterate
	ρ_hat = actual_fct_decrease / (predicted_fct_decrease + guarantee_factor)
	if print_level >= 1 && ρ_hat == -Inf || isnan(ρ_hat)
		println("ρ_hat is $ρ_hat. actual_fct_decrease is $actual_fct_decrease, predicted_fct_decrease is $predicted_fct_decrease, and guarantee_factor is $guarantee_factor.")
	end
    return ρ_hat, actual_fct_decrease, predicted_fct_decrease, guarantee_factor
end

function compute_ρ_standard_trust_region_method(fval_current::Float64, fval_next::Float64, gval_current::Vector{Float64}, H, d_k::Vector{Float64}, print_level::Int64=0)
    second_order_model_value_current_iterate = computeSecondOrderModel(fval_current, gval_current, H, d_k)
	actual_fct_decrease = fval_current - fval_next
	predicted_fct_decrease = - second_order_model_value_current_iterate
	ρ = actual_fct_decrease / predicted_fct_decrease
	if print_level >= 1 && ρ == -Inf || isnan(ρ)
		println("ρ is $ρ. actual_fct_decrease is $actual_fct_decrease and predicted_fct_decrease is $predicted_fct_decrease.")
	end
    return ρ, actual_fct_decrease, predicted_fct_decrease
end

function sub_routine_trust_region_sub_problem_solver(fval_current, gval_current, hessian_current, x_k, δ_k, γ_1, γ_2, r_k, min_gval_norm, nlp, subproblem_solver_method, print_level)
	fval_next = fval_current
	gval_next_temp = gval_current
	start_time_temp = time()
	temp_total_function_evaluation = 0

	# Solve the trust-region subproblem to generate the search direction d_k
	# success_subproblem_solve, δ_k, d_k, temp_total_number_factorizations, hard_case = solveTrustRegionSubproblem(fval_current, gval_current, hessian_current, x_k, δ_k, γ_2, r_k, min_gval_norm, nlp.meta.name, subproblem_solver_method, print_level)
	name = 	getProblemName(nlp)

	success_subproblem_solve, δ_k, d_k, temp_total_number_factorizations, hard_case, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration = solveTrustRegionSubproblem(fval_current, gval_current, hessian_current, x_k, δ_k, γ_2, r_k, min_gval_norm, name, subproblem_solver_method, print_level)
	if success_subproblem_solve
		q_1 = norm(hessian_current * d_k + gval_current + δ_k * d_k)
		q_2 = γ_1 * min_gval_norm
		if q_1 > q_2
			success_subproblem_solve = false
			@warn "q_1: $q_1 is larger than q_2: $q_2."
		end
	end
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	if print_level >= 2
		println("solveTrustRegionSubproblem operation took $total_time_temp.")
	end

	start_time_temp = time()
	second_order_model_value_current_iterate = computeSecondOrderModel(fval_current, gval_current, hessian_current, d_k)
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	if print_level >= 2
		println("computeSecondOrderModel operation took $total_time_temp.")
	end

	# When we are able to solve the trust-region subproblem, we check for numerical error
	# in computing the predicted reduction from the second order model M_k. If no numerical
	# errors, we compute the objective function for the candidate solution to check if
	# we will accept the step in case this leads to reduction in the function value.
	if success_subproblem_solve && second_order_model_value_current_iterate < 0
		start_time_temp = time()
		fval_next = evalFunction(nlp, x_k + d_k)
		temp_total_function_evaluation += 1
		end_time_temp = time()
		total_time_temp = end_time_temp - start_time_temp
		if print_level >= 2
			println("fval_next operation took $total_time_temp.")
		end
	end

	return fval_next, success_subproblem_solve, δ_k, d_k, temp_total_number_factorizations, temp_total_function_evaluation, hard_case, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
end


function power_iteration(A; num_iter=20, tol=1e-6)
    n = size(A, 1)
    v = rand(n)  # Initialize a random vector
    v /= norm(v)  # Normalize the vector

    λ = 0.0  # Initialize the largest eigenvalue
    for i in 1:num_iter
        Av = A * v
        v_new = Av / norm(Av)  # Normalize the new vector
        λ_new = dot(v_new, A * v_new)  # Rayleigh quotient

        # Check for convergence
        if abs(λ_new - λ) < tol
            break
        end

        v = v_new
        λ = λ_new
    end
    return λ, v
end

function matrix_l2_norm(A; num_iter=20, tol=1e-6)
    λ_max, _ = power_iteration(A; num_iter=num_iter, tol=tol)  # Largest eigenvalue of A^T A
    return abs(λ_max)  # Largest singular value (spectral norm)
end

function CAT_solve(m::JuMP.Model)
    nlp_raw = MathOptNLPModel(m)
    return CAT_solve(nlp_raw)
end

function CAT_solve(m::JuMP.Model, pars::Problem_Data)
    nlp_raw = MathOptNLPModel(m)
    return CAT_solve(nlp_raw, pars)
end

function CAT_solve(nlp_raw::NLPModels.AbstractNLPModel)
    pars = Problem_Data()
    return CAT_solve(nlp_raw, pars)
end

function _i_not_fixed(variable_info::Vector{VariableInfo})
    vector_indixes = zeros(Int64, 0)
    for i in 1:length(variable_info)
        if !variable_info[i].is_fixed
            push!(vector_indixes, i)
        end
    end
    return vector_indixes
end

function CAT_solve(solver::CATSolver, pars::Problem_Data)
	ind = _i_not_fixed(solver.variable_info)
    non_fixed_variables = solver.variable_info[ind]
    starting_points_vector = zeros(0)
    for variable in non_fixed_variables
        push!(starting_points_vector, variable.start == nothing ? 0.0 : variable.start)
    end
	x = deepcopy(starting_points_vector)
	δ = 0.0
	pars.nlp = solver.nlp_data
	return CAT(pars, x, δ, subproblem_solver_methods.OPTIMIZATION_METHOD_DEFAULT)
end

function CAT_solve(nlp_raw::NLPModels.AbstractNLPModel, pars::Problem_Data)
	if ncon(nlp_raw) > 0
		throw(ErrorException("Constrained minimization problems are unsupported"))
	end
	pars.nlp = nlp_raw
	subproblem_solver_method = subproblem_solver_methods.OPTIMIZATION_METHOD_DEFAULT
	δ = 0.0
	x = nlp_raw.meta.x0
	return CAT(pars, x, δ, subproblem_solver_method)
end

function CAT(problem::Problem_Data, x::Vector{Float64}, δ::Float64, subproblem_solver_method::String=subproblem_solver_methods.OPTIMIZATION_METHOD_DEFAULT)
	start_time_ = time()
	@assert(δ >= 0)
	#Termination conditions
	termination_conditions_struct = problem.termination_conditions_struct
    MAX_ITERATIONS = termination_conditions_struct.MAX_ITERATIONS
    MAX_TIME = termination_conditions_struct.MAX_TIME
    gradient_termination_tolerance = termination_conditions_struct.gradient_termination_tolerance
	STEP_SIZE_LIMIT = termination_conditions_struct.STEP_SIZE_LIMIT
	MINIMUM_OBJECTIVE_FUNCTION = termination_conditions_struct.MINIMUM_OBJECTIVE_FUNCTION

	#Algorithm parameters
    β_1 = problem.β_1
    ω_1 = problem.ω_1
	ω_2 = problem.ω_2
	γ_1 = problem.γ_1
	γ_2 = problem.γ_2
	γ_3 = 1.0 # //TODO Make param
	θ = problem.θ
	C = (2 + 3 * γ_3 * (1 - β_1)) / (3 * (γ_3 * (1 - 2 * γ_1) * (1 - β_1) - β_1 * θ))
	ξ = 0.1# //TODO Make param
	# @assert ξ >= 1 / (6 * C)
	#Initial radius
	initial_radius_struct = problem.initial_radius_struct
	r_1 = initial_radius_struct.r_1
	INITIAL_RADIUS_MULTIPLICATIVE_RULEE = initial_radius_struct.INITIAL_RADIUS_MULTIPLICATIVE_RULEE

	#Initial conditions
    x_k = x
    δ_k = δ
    r_k = r_1

    nlp = problem.nlp
	@assert nlp != nothing
	print_level = problem.print_level
	compute_ρ_hat_approach = problem.compute_ρ_hat_approach
	radius_update_rule_approach = problem.radius_update_rule_approach

	#Algorithm history
	iteration_stats = DataFrame(k = [], fval = [], gradval = [])

	#Algorithm stats
	total_function_evaluation = 0
    total_gradient_evaluation = 0
    total_hessian_evaluation = 0
    total_number_factorizations = 0
	total_number_factorizations_findinterval = 0
	total_number_factorizations_bisection = 0
	total_number_factorizations_compute_search_direction = 0
	total_number_factorizations_inverse_power_iteration = 0

    k = 1
    try
        gval_current = evalGradient(nlp, x_k)
        fval_current = evalFunction(nlp, x_k)
        total_function_evaluation += 1
        total_gradient_evaluation += 1
		hessian_current = evalHessian(nlp, x_k)
		total_hessian_evaluation += 1

		#If user doesn't change the starting radius, we select the radius as described in the paper:
		#Initial radius heuristic selection rule : r_1 = 10 * ||gval_current|| / ||hessian_current||
		if r_k <= 0.0
			r_k = INITIAL_RADIUS_MULTIPLICATIVE_RULEE * norm(gval_current, 2) / matrix_l2_norm(hessian_current, num_iter=20)
		end

        compute_hessian = false
        if norm(gval_current, 2) <= gradient_termination_tolerance
			total_number_factorization = 1
			computation_stats = Dict("total_function_evaluation" => total_function_evaluation, "total_gradient_evaluation" => total_gradient_evaluation, "total_hessian_evaluation" => total_hessian_evaluation, "total_number_factorizations" => total_number_factorizations, "total_number_factorizations_findinterval" => total_number_factorizations_findinterval, "total_number_factorizations_bisection" => total_number_factorizations_bisection, "total_number_factorizations_compute_search_direction" => total_number_factorizations_compute_search_direction, "total_number_factorizations_inverse_power_iteration" => total_number_factorizations_inverse_power_iteration)
			if print_level >= 0
            	println("*********************************Iteration Count: ", 1)
			end
			push!(iteration_stats, (1, fval_current, norm(gval_current, 2)))
			end_time_ = time()
			total_execution_time = end_time_ - start_time_
			return x_k, TerminationStatusCode.OPTIMAL, iteration_stats, computation_stats, 1, total_execution_time
        end

        start_time = time()
		min_gval_norm = norm(gval_current, 2)
        while k <= MAX_ITERATIONS
			@assert total_number_factorizations == total_number_factorizations_findinterval + total_number_factorizations_bisection + total_number_factorizations_compute_search_direction + total_number_factorizations_inverse_power_iteration
			temp_grad = gval_current
			if print_level >= 1
				start_time_str = Dates.format(now(), "mm/dd/yyyy HH:MM:SS")
				println("$start_time. Iteration $k with radius $r_k and total_number_factorizations $total_number_factorizations.")
			end
            if compute_hessian
				start_time_temp = time()
                hessian_current = evalHessian(nlp, x_k)
				total_hessian_evaluation += 1
				end_time_temp = time()
				total_time_temp = end_time_temp - start_time_temp
				if print_level >= 2
					println("hessian_current operation took $total_time_temp.")
				end
            end

			# Solve the trsut-region subproblem and generate the search direction d_k
			# fval_next, success_subproblem_solve, δ_k, d_k, temp_total_number_factorizations, temp_total_function_evaluation, hard_case = sub_routine_trust_region_sub_problem_solver(fval_current, gval_current, hessian_current, x_k, δ_k, γ_1, γ_2, r_k, min_gval_norm, nlp, subproblem_solver_method, print_level)
			# total_number_factorizations += temp_total_number_factorizations
			# total_function_evaluation += temp_total_function_evaluation
			fval_next, success_subproblem_solve, δ_k, d_k, temp_total_number_factorizations, temp_total_function_evaluation, hard_case, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration = sub_routine_trust_region_sub_problem_solver(fval_current, gval_current, hessian_current, x_k, δ_k, γ_1, γ_2, r_k, min_gval_norm, nlp, subproblem_solver_method, print_level)
			total_number_factorizations_findinterval += temp_total_number_factorizations_findinterval
			total_number_factorizations_bisection += temp_total_number_factorizations_bisection
			total_number_factorizations_compute_search_direction += temp_total_number_factorizations_compute_search_direction
			total_number_factorizations_inverse_power_iteration += temp_total_number_factorizations_inverse_power_iteration

			total_number_factorizations += temp_total_number_factorizations
			total_function_evaluation += temp_total_function_evaluation
			gval_next = gval_current
			# When we are able to solve the trust-region subproblem, we compute ρ_k to check if the
			# candidate solution has a reduction in the function value so that we accept the step by
			if success_subproblem_solve
				if fval_next <= fval_current + ξ * min_gval_norm * norm(d_k) + (1 + abs(fval_current)) * 1e-8
					total_gradient_evaluation += 1
					temp_grad = evalGradient(nlp, x_k + d_k)
					temp_norm = norm(temp_grad, 2)
					if isnan(temp_norm)
						if print_level >= 0
							println("$k. grad(nlp, x_k + d_k) is NaN.")
						end
						@warn "$k grad(nlp, x_k + d_k) is NaN."
					else
						min_gval_norm = min(min_gval_norm, temp_norm)
					end
				end

				start_time_temp = time()
				ρ_k, actual_fct_decrease, predicted_fct_decrease = compute_ρ_standard_trust_region_method(fval_current, fval_next, gval_current, hessian_current, d_k, print_level)
				end_time_temp = time()
				total_time_temp = end_time_temp - start_time_temp
				if print_level >= 2
					println("compute_ρ_standard_trust_region_method operation took $total_time_temp.")
				end

				# Check for numerical error if the predicted reduction from the second order morel is negative.
				# In case it is negative, attempt to solve the trust-region subproblem using our default approach
				# only in case the original trust-region subproblem solver was different than the default approach
				if predicted_fct_decrease <= 0 && subproblem_solver_method != subproblem_solver_methods.OPTIMIZATION_METHOD_DEFAULT
					if print_level >= 1
						println("Predicted function decrease is $predicted_fct_decrease >=0. fval_current is $fval_current and fval_next is $fval_next.")
					end
					@warn "Predicted function decrease is $predicted_fct_decrease >=0. fval_current is $fval_current and fval_next is $fval_next."
					if print_level >= 3
						hessian_current_matrix = Matrix(hessian_current)
						println("Radius, Gradient, and Hessian are $r_k, $gval_current, and $hessian_current_matrix.")
					end
					if print_level >= 1
						println("Solving trust-region subproblem using our approach.")
					end

					# Solve the trsut-region subproblem and generate the search direction d_k
					# fval_next, success_subproblem_solve, δ_k, d_k, temp_total_number_factorizations, temp_total_function_evaluation, hard_case = sub_routine_trust_region_sub_problem_solver(fval_current, gval_current, hessian_current, x_k, δ_k, γ_1, γ_2, r_k, min_gval_norm, nlp, subproblem_solver_methods.OPTIMIZATION_METHOD_DEFAULT, print_level)
					# total_number_factorizations += temp_total_number_factorizations
					# total_function_evaluation += temp_total_function_evaluation
					fval_next, success_subproblem_solve, δ_k, d_k, temp_total_number_factorizations, temp_total_function_evaluation, hard_case, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration = sub_routine_trust_region_sub_problem_solver(fval_current, gval_current, hessian_current, x_k, δ_k, γ_1, γ_2, r_k, min_gval_norm, nlp, subproblem_solver_methods.OPTIMIZATION_METHOD_DEFAULT, print_level)
					total_number_factorizations_findinterval += temp_total_number_factorizations_findinterval
					total_number_factorizations_bisection += temp_total_number_factorizations_bisection
					total_number_factorizations_compute_search_direction += temp_total_number_factorizations_compute_search_direction
					total_number_factorizations_inverse_power_iteration += temp_total_number_factorizations_inverse_power_iteration
					total_number_factorizations += temp_total_number_factorizations
					total_function_evaluation += temp_total_function_evaluation

					# When we are able to solve the trust-region subproblem, we compute ρ_k to check if the
					# candidate solution has a reduction in the function value so that we accept the step by
					if success_subproblem_solve
						if fval_next <= fval_current + ξ * min_gval_norm * norm(d_k) + (1 + abs(fval_current)) * 1e-8
							total_gradient_evaluation += 1
							temp_grad = evalGradient(nlp, x_k + d_k)
							temp_norm = norm(temp_grad, 2)
							if isnan(temp_norm)
								if print_level >= 0
									println("$k. grad(nlp, x_k + d_k) is NaN.")
								end
								@warn "$k grad(nlp, x_k + d_k) is NaN."
							else
								min_gval_norm = min(min_gval_norm, temp_norm)
							end
						end

						start_time_temp = time()
						ρ_k, actual_fct_decrease, predicted_fct_decrease = compute_ρ_standard_trust_region_method(fval_current, fval_next, gval_current, hessian_current, d_k, print_level)
						end_time_temp = time()
						total_time_temp = end_time_temp - start_time_temp
						if print_level >= 2
							println("compute_ρ_standard_trust_region_method operation took $total_time_temp.")
						end
						# Check for numerical error if the predicted reduction from the second order morel is negative.
						# In case it is negative, mark the solution of the trust-region subproblem as failure
						# by setting ρ_k to a negative default value (-1.0) and  the search direction d_k to 0 vector
						if predicted_fct_decrease <= 0.0
							if print_level >= 1
								println("Predicted function decrease is $predicted_fct_decrease >=0. fval_current is $fval_current and fval_next is $fval_next.")
							end
							@warn "Predicted function decrease is $predicted_fct_decrease >=0. fval_current is $fval_current and fval_next is $fval_next."
							ρ_k = -1.0
							actual_fct_decrease = 0.0
							predicted_fct_decrease = 0.0
							d_k = zeros(length(x_k))
						end
					else
						# In case we fail to solve the trust-region subproblem using our default solver, we mark that as a failure
						# by setting ρ_k to a negative default value (-1.0) and  the search direction d_k to 0 vector
						ρ_k = -1.0
						actual_fct_decrease = 0.0
						predicted_fct_decrease = 0.0
						d_k = zeros(length(x_k))
					end
				end
			else
				# In case we failt to solve the trust-region subproblem, we mark that as a failure
				# by setting ρ_k to a negative default value (-1.0) and  the search direction d_k to 0 vector
				ρ_k = -1.0
				actual_fct_decrease = 0.0
				predicted_fct_decrease = 0.0
				d_k = zeros(length(x_k))
			end
			if print_level >= 1
				println("Iteration $k with fval_next is $fval_next and fval_current is $fval_current.")
				println("Iteration $k with actual_fct_decrease is $actual_fct_decrease and predicted_fct_decrease is $predicted_fct_decrease.")
			end

			ρ_hat_k = ρ_k
			norm_gval_current = norm(gval_current, 2)
			norm_gval_next = norm_gval_current
			# Accept the generated search direction d_k when ρ_k is positive
			# and compute ρ_hat_k for the radius update rule
			if ρ_k >= 0.0 && (fval_next <= fval_current)
				if print_level >= 1
					println("$k. =======STEP IS ACCEPTED========== $ρ_k =========fval_next is $fval_next and fval_current is $fval_current.")
				end
				x_k = x_k + d_k
				start_time_temp = time()
				gval_next = temp_grad
				if isnan(min_gval_norm)
					if print_level >= 0
						println("$k. min_gval_norm is NaN")
					end
					@warn "$k min_gval_norm is NaN."
				end
				end_time_temp = time()
				total_time_temp = end_time_temp - start_time_temp
				if print_level >= 2
					println("gval_next operation took $total_time_temp.")
				end
				start_time_temp = time()
				ρ_hat_k, actual_fct_decrease, predicted_fct_decrease, guarantee_factor = compute_ρ_hat(fval_current, fval_next, gval_current, gval_next, hessian_current, d_k, θ, min_gval_norm, print_level, compute_ρ_hat_approach)
				end_time_temp = time()
				total_time_temp = end_time_temp - start_time_temp
				if print_level >= 2
					println("compute_ρ_hat operation took $total_time_temp.")
				end

                fval_current = fval_next
                gval_current = gval_next
				compute_hessian = true
            else
                #else x_k+1 = x_k, fval_current, gval_current, hessian_current will not change
                compute_hessian = false
            end
			if print_level >= 1
				println("$k. ρ_hat_k is $ρ_hat_k.")
				println("$k. hard_case is $hard_case")
				norm_d_k = norm(d_k, 2)
				println("$k. r_k is $r_k and ||d_k|| is $norm_d_k.")
			end

			# Radius update
			if radius_update_rule_approach == "DEFAULT"
				if !success_subproblem_solve || isnan(ρ_hat_k) || ρ_hat_k < β_1
					r_k = r_k / ω_1
				else
					r_k = max(ω_2 * norm(d_k, 2), r_k)
				end
			# This to be able to test the performance of the algorithm for the ablation study
			else
				if !success_subproblem_solve
					r_k = r_k / ω_1
				else
					if isnan(ρ_hat_k) || ρ_hat_k < β_1
						r_k = norm(d_k, 2) / ω_1
					else
						r_k = ω_1 * norm(d_k, 2)
					end
				end
			end

			push!(iteration_stats, (k, fval_current, norm(gval_current, 2)))
			if ρ_k < 0 && min(min_gval_norm, norm(evalGradient(nlp, x_k + d_k), 2)) <= gradient_termination_tolerance
				@info "========Convergence without accepting step========="
				if print_level >= 0
					println("========Convergence without accepting step=========")
				end
			end
			# Check termination condition for gradient
			if norm(gval_next, 2) <= gradient_termination_tolerance ||  min_gval_norm <= gradient_termination_tolerance
				push!(iteration_stats, (k, fval_next, min_gval_norm))
				computation_stats = Dict("total_function_evaluation" => total_function_evaluation, "total_gradient_evaluation" => total_gradient_evaluation, "total_hessian_evaluation" => total_hessian_evaluation, "total_number_factorizations" => total_number_factorizations, "total_number_factorizations_findinterval" => total_number_factorizations_findinterval, "total_number_factorizations_bisection" => total_number_factorizations_bisection, "total_number_factorizations_compute_search_direction" => total_number_factorizations_compute_search_direction, "total_number_factorizations_inverse_power_iteration" => total_number_factorizations_inverse_power_iteration)
				if print_level >= 0
	            	println("*********************************Iteration Count: ", k)
				end
				if print_level >= 2
					try
						cholesky(Matrix(hessian_current))
						println("==============Local Minimizer=============")
					catch e
						println("==============Saddle Point=============")
					end
				end
				end_time_ = time()
				total_execution_time = end_time_ - start_time_
				return x_k, TerminationStatusCode.OPTIMAL, iteration_stats, computation_stats, k, total_execution_time
	        end

			# Check termination condition for trust-region radius if it becomes too small
			if r_k <= STEP_SIZE_LIMIT || 0 < norm(d_k) <= STEP_SIZE_LIMIT
				computation_stats = Dict("total_function_evaluation" => total_function_evaluation, "total_gradient_evaluation" => total_gradient_evaluation, "total_hessian_evaluation" => total_hessian_evaluation, "total_number_factorizations" => total_number_factorizations, "total_number_factorizations_findinterval" => total_number_factorizations_findinterval, "total_number_factorizations_bisection" => total_number_factorizations_bisection, "total_number_factorizations_compute_search_direction" => total_number_factorizations_compute_search_direction, "total_number_factorizations_inverse_power_iteration" => total_number_factorizations_inverse_power_iteration)
				if print_level >= 0
					println("$k. Trust region radius $r_k is too small.")
				end
				end_time_ = time()
				total_execution_time = end_time_ - start_time_
				return x_k, TerminationStatusCode.STEP_SIZE_LIMIT, iteration_stats, computation_stats, k, total_execution_time
			end

			# Check termination condition for function value if the objective function is unbounded (safety check)
			if fval_current <= MINIMUM_OBJECTIVE_FUNCTION || fval_next <= MINIMUM_OBJECTIVE_FUNCTION
				computation_stats = Dict("total_function_evaluation" => total_function_evaluation, "total_gradient_evaluation" => total_gradient_evaluation, "total_hessian_evaluation" => total_hessian_evaluation, "total_number_factorizations" => total_number_factorizations, "total_number_factorizations_findinterval" => total_number_factorizations_findinterval, "total_number_factorizations_bisection" => total_number_factorizations_bisection, "total_number_factorizations_compute_search_direction" => total_number_factorizations_compute_search_direction, "total_number_factorizations_inverse_power_iteration" => total_number_factorizations_inverse_power_iteration)
				if print_level >= 0
					println("$k. Function values ($fval_current, $fval_next) are too small.")
				end
				end_time_ = time()
				total_execution_time = end_time_ - start_time_
				return x_k, TerminationStatusCode.UNBOUNDED, iteration_stats, computation_stats, k, total_execution_time
			end

			# Check termination condition for time if we exceeded the time limit
	        if time() - start_time > MAX_TIME
				computation_stats = Dict("total_function_evaluation" => total_function_evaluation, "total_gradient_evaluation" => total_gradient_evaluation, "total_hessian_evaluation" => total_hessian_evaluation, "total_number_factorizations" => total_number_factorizations, "total_number_factorizations_findinterval" => total_number_factorizations_findinterval, "total_number_factorizations_bisection" => total_number_factorizations_bisection, "total_number_factorizations_compute_search_direction" => total_number_factorizations_compute_search_direction, "total_number_factorizations_inverse_power_iteration" => total_number_factorizations_inverse_power_iteration)
				end_time_ = time()
				total_execution_time = end_time_ - start_time_
				return x_k, TerminationStatusCode.TIME_LIMIT, iteration_stats, computation_stats, k, total_execution_time
	        end
        	k += 1
        end
	# Handle exceptions
    catch e
		@error e
		computation_stats = Dict("total_function_evaluation" => total_function_evaluation, "total_gradient_evaluation" => total_gradient_evaluation, "total_hessian_evaluation" => total_hessian_evaluation, "total_number_factorizations" => total_number_factorizations, "total_number_factorizations_findinterval" => total_number_factorizations_findinterval, "total_number_factorizations_bisection" => total_number_factorizations_bisection, "total_number_factorizations_compute_search_direction" => total_number_factorizations_compute_search_direction, "total_number_factorizations_inverse_power_iteration" => total_number_factorizations_inverse_power_iteration)
		status = TerminationStatusCode.OTHER_ERROR
		if isa(e, OutOfMemoryError)
			status = TerminationStatusCode.MEMORY_LIMIT
		end
		end_time_ = time()
		total_execution_time = end_time_ - start_time_
		return x_k, status, iteration_stats, computation_stats, k, total_execution_time
    end
	computation_stats = Dict("total_function_evaluation" => total_function_evaluation, "total_gradient_evaluation" => total_gradient_evaluation, "total_hessian_evaluation" => total_hessian_evaluation, "total_number_factorizations" => total_number_factorizations, "total_number_factorizations_findinterval" => total_number_factorizations_findinterval, "total_number_factorizations_bisection" => total_number_factorizations_bisection, "total_number_factorizations_compute_search_direction" => total_number_factorizations_compute_search_direction, "total_number_factorizations_inverse_power_iteration" => total_number_factorizations_inverse_power_iteration)
	end_time_ = time()
	total_execution_time = end_time_ - start_time_
	return x_k, TerminationStatusCode.ITERATION_LIMIT, iteration_stats, computation_stats, k, total_execution_time
end

function evalFunction(nlp, x)
	if typeof(nlp) == AbstractNLPModel || typeof(nlp) ==  MathOptNLPModel
		return obj(nlp, x)
	else
		return MOI.eval_objective(nlp.evaluator, x)
	end
end

function getProblemName(nlp)
	if typeof(nlp) == AbstractNLPModel || typeof(nlp) ==  MathOptNLPModel
		return nlp.meta.name
	else
		return "Generic"
	end
end

function evalGradient(nlp, x)
	if typeof(nlp) == AbstractNLPModel || typeof(nlp) ==  MathOptNLPModel
		return grad(nlp, x)
	else
		gval = zeros(length(x))
		MOI.eval_objective_gradient(nlp.evaluator, gval, x)
		return gval
	end
end

function restoreFullMatrix(A)
    nmbRows = size(A)[1]
    numbColumns = size(A)[2]
    for i in 1:nmbRows
        for j in i:numbColumns
            A[i, j] = A[j, i]
        end
    end
    return A
end

function evalHessian(nlp, x)
	if typeof(nlp) == AbstractNLPModel || typeof(nlp) ==  MathOptNLPModel
		return hess(nlp, x)
	else
		hessian = spzeros(Float64, (length(x), length(x)))
		d = nlp.evaluator
	    hessian_sparsity = MOI.hessian_lagrangian_structure(d)
	    #Sparse hessian entry vector
	    H_vec = zeros(Float64, length(hessian_sparsity))
	    MOI.eval_hessian_lagrangian(d, H_vec, x, 1.0, zeros(0))
	    if !isempty(hessian_sparsity)
	        index = 1
	        if length(hessian_sparsity) < 3
	            index = length(hessian_sparsity)
	        elseif length(x) > 1
	            index = length(H_vec)
	        end
	        for i in 1:index
	            hessian[hessian_sparsity[i][1], hessian_sparsity[i][2]]+= H_vec[i]
	        end
	    end
		matrix_hessian = Matrix(hessian)
		return restoreFullMatrix(hessian)
	end
end
