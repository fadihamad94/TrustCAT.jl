export phi, findinterval, bisection, findMinimumEigenValue
using LinearAlgebra
using Dates
using Roots
using LinearMaps
using IterativeSolvers
#=
The big picture idea here is to optimize the trust region subproblem using a factorization method based
on the optimality conditions:
H d_k + g + δ d_k = 0
H + δ I ≥ 0
δ(r -  ||d_k ||) = 0

That is why we defined the below phi to solve that using bisection logic.
=#

const OPTIMIZATION_METHOD_TRS = "GALAHAD_TRS"
const OPTIMIZATION_METHOD_GLTR = "GALAHAD_GLTR"
const OPTIMIZATION_METHOD_DEFAULT = "OUR_APPROACH"

const LIBRARY_PATH_TRS = string(@__DIR__ ,"/../lib/trs.so")
const LIBRARY_PATH_GLTR = string(@__DIR__ ,"/../lib/gltr.so")

mutable struct Subproblem_Solver_Methods
    OPTIMIZATION_METHOD_TRS::String
    OPTIMIZATION_METHOD_GLTR::String
    OPTIMIZATION_METHOD_DEFAULT::String
    function Subproblem_Solver_Methods()
        return new(OPTIMIZATION_METHOD_TRS, OPTIMIZATION_METHOD_GLTR, OPTIMIZATION_METHOD_DEFAULT)
    end
end

const subproblem_solver_methods = Subproblem_Solver_Methods()

function if_mkpath(dir::String)
  if !isdir(dir)
     mkpath(dir)
  end
end

struct userdata_type_trs
	status::Cint
	factorizations::Cint
	hard_case::Cuchar
	multiplier::Cdouble
end

#Data returned by calling the GALAHAD library in case we solve trust region subproblem
#using their GLTR approach
struct userdata_type_gltr
	status::Cint
	iter::Cint
	obj::Cdouble
	hard_case::Cuchar
	multiplier::Cdouble
	mnormx::Cdouble
end

function getHessianDenseLowerTriangularPart(H)
	h_vec = Vector{Float64}()
	for i in 1:size(H)[1]
		for j in 1:i
			push!(h_vec, H[i, j])
		end
	end
	return h_vec
end


function getHessianSparseLowerTriangularPart(H)
	H_ne = 0
	H_val = Vector{Float64}()
	H_row = Vector{Int32}()
	H_col= Vector{Int32}()
	H_ptr = Vector{Int32}()
	temp = 0
	if H[1, 1] != 0
		push!(H_ptr, 0)
	end
	for i in 1:size(H)[1]
		for j in 1:i
			if H[i, j] != 0.0
				if temp == 0
					temp = H_ne
				end
				H_ne += 1
				push!(H_val, H[i, j])
				push!(H_row, i - 1)
				push!(H_col, j - 1)
			end
		end
		if temp != 0
			push!(H_ptr, temp)
		end
		temp = 0
	end
	#push!(H_ptr, size(H)[1] + 1)
	push!(H_ptr, H_ne)
	return H_ne, H_val, H_row, H_col, H_ptr
end


function solveTrustRegionSubproblem(f::Float64, g::Vector{Float64}, H, x_k::Vector{Float64}, δ::Float64, γ_2::Float64, r::Float64, min_grad::Float64, problem_name::String, subproblem_solver_method::String=subproblem_solver_methods.OPTIMIZATION_METHOD_DEFAULT, print_level::Int64=0)
	if subproblem_solver_method == OPTIMIZATION_METHOD_DEFAULT
		return optimizeSecondOrderModel(g, H, δ, γ_2, r, min_grad, print_level)
	end

	if subproblem_solver_method == OPTIMIZATION_METHOD_TRS
		return trs(f, g, H, δ, γ_2, r, problem_name, min_grad, print_level)
	end

	if subproblem_solver_method == OPTIMIZATION_METHOD_GLTR
		return gltr(f, g, H, r, min_grad, print_level)
	end

	return optimizeSecondOrderModel(g, H, δ, γ_2, r, min_grad, print_level)
end

function trs(f::Float64, g::Vector{Float64}, H, δ::Float64, γ_2::Float64, r::Float64, problem_name::String, min_grad::Float64, print_level::Int64=0)
    max_factorizations = 1000
	H_type = "sparse_by_rows"
	#H_type = "dense"
	#H_type = "coordinate"
	H_ne = 0
	H_val = Nothing
	H_row = Nothing
	H_col = Nothing
	H_ptr = Nothing
	if H_type == "dense"
		H_val = getHessianDenseLowerTriangularPart(H)
		H_ne = length(H_val)
		H_row = [Int32(0)]
		H_col = [Int32(0)]
		H_ptr = [Int32(0)]
	else
		start_time_temp = time()
		H_ne, H_val, H_row, H_col, H_ptr = getHessianSparseLowerTriangularPart(H)
		end_time_temp = time()
		total_time_temp = end_time_temp - start_time_temp
		@info "getHessianSparseLowerTriangularPart operation took $total_time_temp."
		if print_level >= 2
			println("getHessianSparseLowerTriangularPart operation took $total_time_temp.")
		end
	end
	d = zeros(length(g))
	full_Path = string(@__DIR__ ,"/test")
	use_initial_multiplier = true
	initial_multiplier = δ
	use_stop_args = true
	stop_normal = 1e-5
    stop_hard = 1e-5
	if H_type == "sparse_by_rows" && length(H_ptr) != length(g) + 1
		@warn "Weired case detected."
		H_type = "coordinate"
	end
	# Convert the Julia string to a C-compatible representation (Cstring)
	string_problem_name = string(@__DIR__ ,"/../DEBUG_TRS/$problem_name.csv")
	if print_level >= 0
		if_mkpath(string(@__DIR__ ,"/../DEBUG_TRS"))
		if !isfile(string_problem_name)
			open(string_problem_name,"a") do iteration_status_csv_file
				write(iteration_status_csv_file, "status,hard_case,x_norm,radius,multiplier,lambda,len_history,factorizations\n");
	    	end
		end
	end

	start_time = Dates.format(now(), "mm/dd/yyyy HH:MM:SS")
	start_time_temp = time()
	userdata = ccall((:trs, LIBRARY_PATH_TRS), userdata_type_trs, (Cint, Cint, Cstring, Cdouble, Ref{Cdouble}, Ref{Cdouble}, Ref{Cdouble}, Ref{Cint}, Ref{Cint}, Ref{Cint}, Cdouble, Cint, Cint, Cuchar, Cdouble, Cuchar, Cdouble, Cdouble, Cstring), length(g), H_ne, H_type, f, d, g, H_val, H_row, H_col, H_ptr, r, print_level, max_factorizations, use_initial_multiplier, initial_multiplier, use_stop_args, stop_normal, stop_hard, string_problem_name)
	end_time = Dates.format(now(), "mm/dd/yyyy HH:MM:SS")
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	@info "calling GALAHAD operation took $total_time_temp."
	if print_level >= 2
		println("calling GALAHAD operation took $total_time_temp.")
	end

	tol = 1e-1
	condition_success = norm(d, 2) - r <= tol || abs(norm(d, 2) - r) <= stop_normal * r + tol || abs(norm(d, 2) - r) <= stop_normal + tol
	total_number_factorizations = userdata.factorizations
	if userdata.status != 0 || !condition_success
		if print_level >= 1
			println("Failed to solve trust region subproblem using TRS factorization method from GALAHAD. Status is $(userdata.status).")
		end
		if userdata.status == 0
			norm_d = norm(d, 2)
			@warn "Solution isn't inside the trust-region. ||d_k|| = $norm_d but radius is $r."
			if print_level >= 1
				println("Solution isn't inside the trust-region. ||d_k|| = $norm_d but radius is $r.")
			end
		else
			if print_level >= 0
				@warn "Failed to solve trust region subproblem using TRS factorization method from GALAHAD. Status is $(userdata.status)."
			end
		end
		# This code was used when getting the preliminary results. Maybe we need it later
		# start_time_temp = time()
		# δ = max(δ, abs(eigmin(Matrix(H))))
		# end_time_temp = time()
		# total_time_temp = end_time_temp - start_time_temp
		# println("eigmin operation took $total_time_temp.")
		try
			start_time_temp = time()
			success, δ, d_k, temp_total_number_factorizations, hard_case = optimizeSecondOrderModel(g, H, δ, stop_normal, r, min_grad, print_level)
			total_number_factorizations += temp_total_number_factorizations
			end_time_temp = time()
			total_time_temp = end_time_temp - start_time_temp
			@info "$success. optimizeSecondOrderModel operation took $total_time_temp."
			if print_level >= 2
				println("optimizeSecondOrderModel operation took $total_time_temp.")
			end
			return success, δ, d_k, total_number_factorizations, hard_case
		catch e
			@error e
			throw(e)
		end
	end

    multiplier = userdata.multiplier
	hard_case = Bool(userdata.hard_case != 0)
    return true, multiplier, d, total_number_factorizations, hard_case
end

function gltr(f::Float64, g::Vector{Float64}, H, r::Float64, min_grad::Float64, print_level::Int64=0)
    iter = 10000
	H_dense = getHessianDenseLowerTriangularPart(H)
	d = zeros(length(g))
	stop_relative = 1.5e-8
	stop_relative = min(1e-6 * min_grad, 1e-6)
	stop_absolute = 0.0
	steihaug_toint = false
	stop_absolute = 0.0
	stop_relative = 0.0
	userdata = ccall((:gltr, LIBRARY_PATH_GLTR), userdata_type_gltr, (Cint, Cdouble, Ref{Cdouble}, Ref{Cdouble}, Ref{Cdouble}, Cdouble, Cint, Cint, Cdouble, Cdouble, Cuchar), length(g), f, d, g, H_dense, r, print_level, iter, stop_relative, stop_absolute, steihaug_toint)
	if userdata.status < 0
		steihaug_toint = true
		stop_relative = min(0.1 * min_grad, 0.1)
		d = zeros(length(g))
		userdata = ccall((:gltr, LIBRARY_PATH_GLTR), userdata_type_gltr, (Cint, Cdouble, Ref{Cdouble}, Ref{Cdouble}, Ref{Cdouble}, Cdouble, Cint, Cint, Cdouble, Cdouble, Cuchar), length(g), f, d, g, H_dense, r, print_level, iter, stop_relative, stop_absolute, steihaug_toint)
	end
	if userdata.status != 0
		throw(error("Failed to solve trust region subproblem using GLTR iterative method from GALAHAD. Status is $(userdata.status)."))
	end
	return true, userdata.multiplier, d, userdata.iter, false
end

#Based on Theorem 4.3 in Numerical Optimization by Wright

function computeSearchDirection(g::Vector{Float64}, H, δ::Float64, γ_2::Float64, r::Float64, total_number_factorizations::Int64, min_grad::Float64, print_level::Int64=0)
	start_time_temp = time()
	if print_level >= 1
		println("STARting FIND INTERVAL")
	end
	success, δ, δ_prime, temp_total_number_factorizations = findinterval(g, H, δ, γ_2, r, print_level)
	total_number_factorizations += temp_total_number_factorizations
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	if print_level >= 2
		println("findinterval operation finished with (δ, δ_prime) = ($δ, $δ_prime) and took $total_time_temp.")
	end

	if !success
		return false, false, δ, δ, δ_prime, zeros(length(g)), total_number_factorizations, false
	end

	start_time_temp = time()
	success, δ_m, δ, δ_prime, temp_total_number_factorizations = bisection(g, H, δ, γ_2, δ_prime, r, min_grad, print_level)
	total_number_factorizations += temp_total_number_factorizations
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	if print_level >= 2
		println("$success. bisection operation took $total_time_temp.")
	end

	if !success
		return true, false, δ_m, δ, δ_prime, zeros(length(g)), total_number_factorizations, false
	end

	sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
	total_number_factorizations  += 1

	start_time_temp = time()
	d_k = cholesky(H + δ_m * sparse_identity) \ (-g)
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	if print_level >= 2
		println("d_k operation took $total_time_temp.")
	end
	return true, true, δ_m, δ, δ_prime, d_k, total_number_factorizations, false
end

function optimizeSecondOrderModel(g::Vector{Float64}, H, δ::Float64, γ_2::Float64, r::Float64, min_grad::Float64, print_level::Int64=0)
    #When δ is 0 and the Hessian is positive semidefinite, we can directly compute the direction
    total_number_factorizations = 0
    try
		total_number_factorizations += 1
        d_k = cholesky(H) \ (-g)
        # if norm(d_k, 2) <= (1 + γ_2) * r
		if norm(d_k, 2) <= r
        	return true, 0.0, d_k, total_number_factorizations, false
        end
    catch e
		#Do nothing
    end
	δ_m = δ
	δ_prime = δ
    try
		success_find_interval, success_bisection, δ_m, δ, δ_prime, d_k, temp_total_number_factorizations, hard_case = computeSearchDirection(g, H, δ, γ_2, r, total_number_factorizations, min_grad, print_level)
		total_number_factorizations += temp_total_number_factorizations
		success = success_find_interval && success_bisection
		if success
			return true, δ_m, d_k, total_number_factorizations, hard_case
		end
		if success_find_interval
			throw(error("Bisection logic failed to find a root for the phi function"))
		else
			throw(error("Bisection logic failed to find a pair δ and δ_prime such that ϕ(δ) >= 0 and ϕ(δ_prime) <= 0."))
		end
    catch e
		println("Error: ", e)
        if e == ErrorException("Bisection logic failed to find a root for the phi function")
			start_time_temp = time()
	    	# success, δ, d_k, temp_total_number_factorizations = solveHardCaseLogic(g, H, γ_2, r, print_level)
			success, δ, d_k, temp_total_number_factorizations = solveHardCaseLogic(g, H, γ_2, r, δ, δ_prime, min_grad, print_level)
			total_number_factorizations += temp_total_number_factorizations
			end_time_temp = time()
			total_time_temp = end_time_temp - start_time_temp
			@info "$success. 1.solveHardCaseLogic operation took $total_time_temp."
			if print_level >= 2
				println("$success. 1.solveHardCaseLogic operation took $total_time_temp.")
			end
            return success, δ, d_k, total_number_factorizations, true
        elseif e == ErrorException("Bisection logic failed to find a pair δ and δ_prime such that ϕ(δ) >= 0 and ϕ(δ_prime) <= 0.")
			@error e
			start_time_temp = time()
            # success, δ, d_k, temp_total_number_factorizations = solveHardCaseLogic(g, H, γ_2, r, print_level)
			success, δ, d_k, temp_total_number_factorizations = solveHardCaseLogic(g, H, γ_2, r, δ, δ_prime, min_grad, print_level)
			total_number_factorizations += temp_total_number_factorizations
			end_time_temp = time()
			total_time_temp = end_time_temp - start_time_temp
			@info "$success. 2.solveHardCaseLogic operation took $total_time_temp."
			if print_level >= 2
				println("$success. 2.solveHardCaseLogic operation took $total_time_temp.")
			end
	    	return success, δ, d_k, total_number_factorizations, true
        else
			@error e
            throw(e)
        end
    end
end


function phi(g::Vector{Float64}, H, δ::Float64, γ_2::Float64, r::Float64, print_level::Int64=0)
    sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
    shifted_hessian = H + δ * sparse_identity
	temp_d = zeros(length(g))
	positive_definite = true
    try
		start_time_temp = time()
        shifted_hessian_fact = cholesky(shifted_hessian)
		end_time_temp = time()
		total_time_temp = end_time_temp - start_time_temp
		if print_level >= 2
			println("cholesky inside phi function took $total_time_temp.")
		end

		start_time_temp = time()
		temp_d = shifted_hessian_fact \ (-g)
		computed_norm = norm(temp_d, 2)
		end_time_temp = time()
		total_time_temp = end_time_temp - start_time_temp
		if print_level >= 2
			println("computed_norm opertion took $total_time_temp.")
		end

		if (δ <= 1e-6 && computed_norm <= r)
			return 0, temp_d, positive_definite
		elseif computed_norm < (1 - γ_2) * r
	        return -1, temp_d, positive_definite
		# elseif abs(computed_norm - r) <= γ_2 * r
		elseif computed_norm <= r
	        return 0, temp_d, positive_definite
	    else
	        return 1, temp_d, positive_definite
	    end
    catch e
		positive_definite = false
        return 1, temp_d, positive_definite
    end
end

function phi(δ::Float64)
	global g_
	global H_
	global γ_2_
	global r_
	global global_temp_total_number_factorizations
    global_temp_total_number_factorizations = global_temp_total_number_factorizations + 1
    sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H_)[1], size(H_)[2])
    shifted_hessian = H_ + δ * sparse_identity
    #cholesky factorization only works on positive definite matrices
    try
		start_time_temp = time()
        cholesky(shifted_hessian)
		end_time_temp = time()
		total_time_temp = end_time_temp - start_time_temp
		println("cholesky inside phi function took $total_time_temp.")

		start_time_temp = time()
		computed_norm = norm(shifted_hessian \ g_, 2)
		end_time_temp = time()
		total_time_temp = end_time_temp - start_time_temp
		println("computed_norm opertion took $total_time_temp.")

		if (δ <= 1e-6 && computed_norm <= r_)
			return 0
		elseif computed_norm < (1 -γ_2_) * r_
	        return -1
		# elseif abs(computed_norm - r_) <= γ_2_ * r_
		elseif computed_norm <= γ_2_ * r_
	        return 0
	    else
	        return 1
	    end
    catch e
        return 1
    end
end


#Old Logic
function findinterval(g::Vector{Float64}, H, δ::Float64, γ_2::Float64, r::Float64, print_level::Int64=0)
	if print_level >= 1
		println("STARTING WITH δ = $δ.")
	end
    Φ_δ, temp_d, positive_definite = phi(g, H, 0.0, γ_2, r)

    if Φ_δ == 0
        δ = 0.0
        δ_prime = 0.0
        return true, δ, δ_prime, 1
    end

	δ_original = δ

	# if δ_original < 1e-6
	# 	δ = 1e-2 * sqrt(δ)
	# end
	# if print_level >= 1
	# 	println("Updating δ to δ = $δ.")
	# end

    Φ_δ, temp_d, positive_definite = phi(g, H, δ, γ_2, r)

    if Φ_δ == 0
        δ_prime = δ
        return true, δ, δ_prime, 2
    end
	if δ < 0
		@warn "---------THIS SHOULD NOT HAPPEN---------"
	end
	δ_prime = δ
	if Φ_δ > 0
		δ_prime = δ == 0.0 ? 1.0 : δ * 2
		# if δ != 0 && δ_original < 1e-6
		# 	δ_prime = 1e-1 * sqrt(δ)
		# end
	else
		if δ == 0
			@warn "---------THIS SHOULD NOT HAPPEN---------"
			return false, δ, δ_prime, 2
		else
			δ_prime = δ
			δ = δ / 2
		end
	end

	#Results with this code
    # δ_prime = δ == 0.0 ? 1.0 : δ * 2
	# if Φ_δ > 0
	# 	if δ != 0.0
	# 		if δ_original < 1e-6
	# 			δ_prime = 1e-1 * sqrt(δ)
	# 		else
	# 			δ_prime = δ * 2 ^ 5
	# 		end
	# 	end
	# else
	# 	if δ != 0.0
	# 		if δ_original < 1e-6
	# 			δ_prime = 0.0
	# 		else
	# 			δ_prime = δ / 2 ^ 5
	# 		end
	# 	end
	# end
	# if δ < 0
	# 	δ_prime = -δ
	# end

    Φ_δ_prime = 0.0
	max_iterations = 100
    k = 1
    while k < max_iterations
        Φ_δ_prime, temp_d, positive_definite = phi(g, H, δ_prime, γ_2, r)
        if Φ_δ_prime == 0
            δ = δ_prime
            return true, δ, δ_prime, k + 2
        end

        if ((Φ_δ * Φ_δ_prime) < 0)
			if print_level >= 1
				println("ENDING WITH ϕ(δ) = $Φ_δ and Φ_δ_prime = $Φ_δ_prime.")
				println("ENDING WITH δ = $δ and δ_prime = $δ_prime.")
			end
            break
        end
        if Φ_δ_prime < 0
            # δ_prime = δ_prime / 2 ^ k
			δ_prime = δ_prime / 2
        elseif Φ_δ_prime > 0
            # δ_prime = δ_prime * 2 ^ k
			δ_prime = δ_prime * 2
        end
        k = k + 1
    end

    #switch so that δ for ϕ_δ >= 0 and δ_prime for ϕ_δ_prime <= 0
	#δ < δ_prime since ϕ is decreasing function
    if Φ_δ_prime > 0 && Φ_δ < 0
        # δ_temp = δ
        # Φ_δ_temp = Φ_δ
        # δ = δ_prime
        # δ_prime = δ_temp
        # Φ_δ = Φ_δ_prime
        # Φ_δ_prime = Φ_δ_temp
		δ, δ_prime = δ_prime, δ
		Φ_δ, Φ_δ_prime = Φ_δ_prime, Φ_δ
    end

    if (Φ_δ  * Φ_δ_prime > 0)
		if print_level >= 1
			println("Φ_δ is $Φ_δ and Φ_δ_prime is $Φ_δ_prime. δ is $δ and δ_prime is $δ_prime.")
		end
		return false, δ, δ_prime, min(k, max_iterations) + 2
    end

	if δ > δ_prime
		δ, δ_prime = δ_prime, δ
	end

    return true, δ, δ_prime, min(k, max_iterations) + 2
end

function bisection(g::Vector{Float64}, H, δ::Float64, γ_2::Float64, δ_prime::Float64, r::Float64, min_grad::Float64, print_level::Int64=0)
    # the input of the function is the two end of the interval (δ,δ_prime)
    # our goal here is to find the approximate δ using classic bisection method
	initial_δ = δ
	if print_level >= 0
		println("****************************STARTING BISECTION with (δ, δ_prime) = ($δ, $δ_prime)**************")
	end
    #Bisection logic
    k = 1
    δ_m = (δ + δ_prime) / 2
	# δ_m = sqrt(δ + δ_prime)
    Φ_δ_m, temp_d, positive_definite = phi(g, H, δ_m, γ_2, r)
	max_iterations = 50  #2 ^ 50 ~ 1e15
	#ϕ_δ >= 0 and ϕ_δ_prime <= 0
	max_iterations = 100
    while (Φ_δ_m != 0) && k <= max_iterations
		start_time_str = Dates.format(now(), "mm/dd/yyyy HH:MM:SS")
		if print_level >= 2
			println("$start_time_str. Bisection iteration $k.")
		end
        if Φ_δ_m > 0
            δ = δ_m
        else
            δ_prime = δ_m
        end
        δ_m = (δ + δ_prime) / 2
		# δ_m = sqrt(δ + δ_prime)
        Φ_δ_m, temp_d, positive_definite = phi(g, H, δ_m, γ_2, r)
		if Φ_δ_m != 0 && abs(δ - δ_prime) <= 1e-11
			δ_prime = 2 * δ_prime
			δ = δ / 2
		end
        k = k + 1
		if Φ_δ_m != 0
			ϕ_δ_prime, d_temp_δ_prime, positive_definite_δ_prime = phi(g, H, δ_prime, γ_2, r)
			ϕ_δ, d_temp_δ, positive_definite_δ = phi(g, H, δ, γ_2, r)
			q_1 = norm(H * d_temp_δ_prime + g + δ_prime * d_temp_δ_prime)
			#Results are using this
			# q_2 = min_grad / (100)
			#Trial
			q_2 = min_grad / (100)
			# if q_1 > 1e-8 * norm(g)
			println("$k===============0Bisection entered here=================")
			if q_1 > 1e-1 * norm(g)
				norm_g = norm(g)
				tremp_g =  1e-1 * norm(g)
				println("$k+++++++++++++$q_1,$norm_g,$tremp_g.")
				@warn q_1, norm(g)
			end
			if q_1 > 1e-1 * min_grad
				tremp_g =  1e-1 * min_grad
				println("$k-------------$q_1,$min_grad,$tremp_g.")
				@warn q_1, norm(g)
			end
			if q_1 > 1e-3 * min_grad
				tremp_g =  1e-3 * min_grad
				println("$k#############$q_1,$min_grad,$tremp_g.")
				@warn q_1, norm(g)
			end
			#Results are using this
			if (abs(δ_prime - δ) <= (min_grad / (1000 * r))) && q_1 <= q_2 && !positive_definite_δ
			#Trial
			# if (abs(δ_prime - δ) <= (min_grad / (1000 * r))) && q_1 <= q_2 && !positive_definite_δ

				# run code with and without the next line, and check it is the same
				# _d_temp_δ_prime = cholesky(H + δ_prime * I) \ -g
				# if norm(_d_temp_δ_prime - d_temp_δ_prime) > 1e-15 * norm(d_temp_δ_prime)
				# 	temp_d_1_norm = norm(_d_temp_δ_prime)
				# 	temp_d_2_norm = norm(d_temp_δ_prime)
				# 	println("BUG _ Caclulation mismatch. norm(_d_temp_δ_prime) is $temp_d_1_norm, but norm(d_temp_δ_prime) is $temp_d_2_norm.")
				# 	error("BUG _ Caclulation mismatch. norm(_d_temp_δ_prime) is $temp_d_1_norm, but norm(d_temp_δ_prime) is $temp_d_2_norm.")
				# end

				println("$k===================norm(H * d_temp_δ_prime + g + δ_prime * d_temp_δ_prime) is $q_1.============")
				println("$k===================min_grad / (100 r) is $q_2.============")
				println("$k===================ϕ_δ_prime is $ϕ_δ_prime.============")

				println("$k===============Bisection entered here=================")
				mimimum_eigenvalue = eigmin(Matrix(H))
				mimimum_eigenvalue_abs = abs(mimimum_eigenvalue)
				@info "$k=============1Bisection Failure New Logic==============$initial_δ,$δ,$mimimum_eigenvalue,$mimimum_eigenvalue_abs."
				println("$k=============1Bisection Failure New Logic==============$initial_δ,$δ,$mimimum_eigenvalue,$mimimum_eigenvalue_abs.")
				break
				# try
				# 	sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
			 	# 	cholesky(H + δ * sparse_identity)
				# catch
				# 	mimimum_eigenvalue = eigmin(Matrix(H))
				# 	mimimum_eigenvalue_abs = abs(mimimum_eigenvalue)
			 	# 	@info "$k=============1Bisection Failure New Logic==============$initial_δ,$δ,$mimimum_eigenvalue,$mimimum_eigenvalue_abs."
				# 	println("$k=============1Bisection Failure New Logic==============$initial_δ,$δ,$mimimum_eigenvalue,$mimimum_eigenvalue_abs.")
			 	# 	break
				# end
			end
		end
    end

    if (Φ_δ_m != 0)
		if print_level >= 1
			println("Φ_δ_m is $Φ_δ_m.")
			println("δ, δ_prime, and δ_m are $δ, $δ_prime, and $δ_m. γ_2 is $γ_2.")
		end
		return false, δ_m, δ, δ_prime, min(k, max_iterations) + 1
    end
	if print_level >= 0
		println("****************************ENDING BISECTION with δ_m = $δ_m**************")
	end
    return true, δ_m, δ, δ_prime, min(k, max_iterations) + 1
end

function solveHardCaseLogic(g::Vector{Float64}, H, γ_2::Float64, r::Float64, δ::Float64, δ_prime::Float64, min_grad::Float64, print_level::Int64=0)
	println("1.solveHardCaseLogicMethod entered here***************")
	@info ("1.solveHardCaseLogicMethod entered here***************")
	sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
	total_number_factorizations = 1
	try
		temp_d_k = cholesky(H + δ_prime * sparse_identity) \ (-g)
		norm_temp_d_k = norm(temp_d_k, 2)
		println("2.solveHardCaseLogicMethod entered here***************")
		@info ("2.solveHardCaseLogicMethod entered here***************")
		# if abs(norm(temp_d_k)  - r) <= γ_2
		if (1 - γ_2) * r <= norm(temp_d_k) <= r
			println("3.solveHardCaseLogicMethod entered here***************")
			@info ("3.solveHardCaseLogicMethod entered here***************")
			return true, δ_prime, temp_d_k, total_number_factorizations
		end
	catch e
		println("4.solveHardCaseLogicMethod entered here***************")
		@info ("4.solveHardCaseLogicMethod entered here***************")
		@error e
	end
	temp_eigenvalue = 0
	try
		# success, eigenvalue, eigenvector, itr = findMinimumEigenValue(H, δ)
		start_time_temp = time()
		success, eigenvalue, eigenvector, itr = inverse_power_iteration(g, H, min_grad, δ, δ_prime, r, γ_2)
		println("5.solveHardCaseLogicMethod entered here***************")
		@info ("5.solveHardCaseLogicMethod entered here***************")
		temp_eigenvalue = eigenvalue
		end_time_temp = time()
	    total_time_temp = end_time_temp - start_time_temp
	    @info "inverse_power_iteration operation took $total_time_temp."
		eigenvalue = abs(eigenvalue)
		temp_d_k = cholesky(H + (eigenvalue + 1e-1) * sparse_identity) \ (-g)
		total_number_factorizations += itr
		norm_temp_d_k = norm(temp_d_k)
		@info "candidate search direction norm is $norm_temp_d_k. r is $r. γ_2 is $γ_2"
		# if abs(norm(temp_d_k) - r) <= γ_2
		if (1 - γ_2) * r <= norm(temp_d_k) <= r
			return true, eigenvalue, temp_d_k, total_number_factorizations
		end
		# if norm(temp_d_k) > (1 + γ_2) * r
		if norm(temp_d_k) > r
			println("FAILURE======candidate search direction norm is $norm_temp_d_k. r is $r. γ_2 is $γ_2")
			@error "This is noit a hard case. candidate search direction norm is $norm_temp_d_k. r is $r. γ_2 is $γ_2"
		end
		return false, eigenvalue, zeros(length(g)), total_number_factorizations
	catch e
		matrix_H = Matrix(H)
		println("6.solveHardCaseLogicMethod entered here***************$matrix_H")
		@info ("6.solveHardCaseLogicMethod entered here***************$matrix_H")
		@error e
		mimimum_eigenvalue = eigmin(Matrix(H))

		println("FAILURE+++++++inverse_power_iteration operation returned non positive matrix. retunred_eigen_value is $temp_eigenvalue and mimimum_eigenvalue is $mimimum_eigenvalue.")
		return false, δ_prime, zeros(length(g)), total_number_factorizations
	end
end

# function findMinimumEigenValue(H, sigma; max_iter=1000, ϵ=1e-3)
# 	success, eigenvalue, eigenvector, itr = inverse_power_iteration(H, sigma, max_iter = max_iter, ϵ = ϵ)
# 	attempt = 5
# 	while attempt >= 0
# 		if success
# 			try
# 				sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
# 				cholesky(H + (abs(eigenvalue) + 1e-1) * sparse_identity)
# 				itr += 1
# 				return success, eigenvalue, eigenvector, itr
# 			catch e
# 				@error e
# 				if eigenvalue > 0
# 					eigenvalue = eigenvalue / 2
# 				else
# 					eigenvalue = 2 * eigenvalue
# 				end
# 				success, eigenvalue, eigenvector, temp_itr = inverse_power_iteration(H, eigenvalue, max_iter = max_iter, ϵ = ϵ)
# 				itr += temp_itr
# 			end
# 		else
# 			if eigenvalue > 0
# 				eigenvalue = eigenvalue / 2
# 			else
# 				eigenvalue = 2 * eigenvalue
# 			end
# 			success, eigenvalue, eigenvector, temp_itr = inverse_power_iteration(H, eigenvalue, max_iter = max_iter, ϵ = ϵ)
# 			itr += temp_itr
# 		end
# 		attempt -= 1
# 	end
# 	if success
# 		try
# 			sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
# 			total_number_factorizations  += 1
# 			cholesky(H + (abs(eigenvalue) + 1e-1) * sparse_identity)
# 			itr += 1
# 			return success, eigenvalue, eigenvector, itr
# 		catch
# 			return false, eigenvalue, eigenvector, itr
# 		end
# 	end
# 	return false, eigenvalue, eigenvector, itr
# end

function inverse_power_iteration(g, H, min_grad, δ, δ_prime, r, γ_2; max_iter=1000, ϵ=1e-3, print_level=2)
   sigma = δ_prime
   start_time_temp = time()
   n = size(H, 1)
   x = ones(n)
   y = ones(n)
   sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
   y_original_fact = cholesky(H + sigma * sparse_identity)
   for k in 1:max_iter
       # Solve (H - sigma * I) * y = x
       y = y_original_fact \ x
	   # y = (H - delta * I) \ x
       y /= norm(y)
       temp_1 = norm(x + y)
       temp_2 = norm(x - y)
       # @info "norm(x + y) = $temp_1 and norm(x - y) = $temp_2."
	   eigenvalue = dot(y, H * y)

	   if norm(H * y + δ_prime * y) <= abs(δ_prime - δ) + (min_grad / (10 ^ 2 * r))
		   @info "======================"
		   #TODO This code just for debugging. Need to be removed
		   mimimum_eigenvalue = eigmin(Matrix(H))
		   @info "Success. Inverse power iteration finished with eigenvalue = $eigenvalue. mimimum_eigenvalue is $mimimum_eigenvalue."
		   try
			cholesky(H + (abs(eigenvalue) + 1e-1) * sparse_identity)
			println("Success. Inverse power iteration finished with eigenvalue = $eigenvalue. mimimum_eigenvalue is $mimimum_eigenvalue.")
       		        return true, eigenvalue, y, k
		   catch
			@info "Failure. Inverse power iteration finished with eigenvalue = $eigenvalue. mimimum_eigenvalue is $mimimum_eigenvalue."
			println("Failure. Inverse power iteration finished with eigenvalue = $eigenvalue. mimimum_eigenvalue is $mimimum_eigenvalue.")
			#DO NOTHING
		   end

		   @info "======================"
		   #return true, eigenvalue, y, k
	   end

	   #Keep as a safety check. This a sign that we can't solve thr trust region subprobelm
       if norm(x + y) <= ϵ || norm(x - y) <= ϵ
		   eigenvalue = dot(y, H * y)
		   #TODO This code just for debugging. Need to be removed
		   mimimum_eigenvalue = eigmin(Matrix(H))
		   try
			cholesky(H + (abs(eigenvalue) + 1e-1) * sparse_identity)
			@info "Success. Inverse power iteration finished with eigenvalue = $eigenvalue. mimimum_eigenvalue is $mimimum_eigenvalue."
       		return true, eigenvalue, y, k
		   catch
			@info "Failure. Inverse power iteration finished with eigenvalue = $eigenvalue. mimimum_eigenvalue is $mimimum_eigenvalue."
			#DO NOTHING
		   end
       end

       x = y
   end
   temp_ = dot(y, H * y)
   #TODO This code just for debugging. Need to be removed
   mimimum_eigenvalue = eigmin(Matrix(H))
   temp_1 = norm(x + y)
   temp_2 = norm(x - y)
   @error ("Inverse power iteration did not converge. computed eigenValue is $temp_. mimimum_eigenvalue is $mimimum_eigenvalue. norm(x + y) = $temp_1 and norm(x - y) = $temp_2.")
   end_time_temp = time()
   total_time_temp = end_time_temp - start_time_temp
   @info "inverse_power_iteration operation took $total_time_temp."
   if print_level >= 2
	   println("inverse_power_iteration operation took $total_time_temp.")
   end
   return false, temp_, y, max_iter
end

#Based on 'THE HARD CASE' section from Numerical Optimization by Wright
function solveHardCaseLogic(g::Vector{Float64}, H, γ_2::Float64, r::Float64, print_level::Int64=0)
    minimumEigenValue = eigmin(Matrix(H))
	if minimumEigenValue >= 0
		Q = eigvecs(Matrix(H))
		eigenvaluesVector = eigvals(Matrix(H))

		temp_d_0 = zeros(length(g))
		for i in 1:length(eigenvaluesVector)
			temp_d_0 = temp_d_0 .- ((Q[:, i]' * g) / (eigenvaluesVector[i] + 0)) * Q[:, i]
	    end

		temp_d_0_norm = norm(temp_d_0, 2)
		less_than_radius = temp_d_0_norm <= r
		if print_level >= 1
			println("temp_d_0_norm is $temp_d_0_norm and ||d(0)|| <= r is $less_than_radius.")
		end
		if less_than_radius
			return true, 0.0, temp_d_0, 0
		end
		if print_level >= 1
			println("minimumEigenValue is $minimumEigenValue")
			println("r is $r")
			println("g is $g")
			H_matrix = Matrix(H)
			println("H is $H_matrix")
		end
		return false, minimumEigenValue, zeros(length(g)), 0
	end
    δ = -minimumEigenValue
	try
		Q = eigvecs(Matrix(H))
		z =  Q[:,1]
		temp_ = dot(z', g)
		if print_level >= 1
			println("Q_1 ^ T g = $temp_.")
			println("minimumEigenValue = $minimumEigenValue.")
		end
	    eigenvaluesVector = eigvals(Matrix(H))

		temp_d = zeros(length(g))
		for i in 1:length(eigenvaluesVector)
			if eigenvaluesVector[i] != minimumEigenValue
	            temp_d = temp_d .- ((Q[:, i]' * g) / (eigenvaluesVector[i] + δ)) * Q[:, i]
	        end
	    end

		temp_d_norm = norm(temp_d, 2)
		less_than_radius_ = temp_d_norm < r
		if print_level >= 1
			println("temp_d_norm is $temp_d_norm and ||d(-λ_1)|| < r is $less_than_radius_.")
		end

		if !less_than_radius_
			if print_level >= 0
				println("This is not a hard case sub-problem.")
			end
			@error "This is not a hard case sub-problem."
			try
				success_find_interval, success_bisection, δ_m, d_k, total_number_factorizations, temp_hard_case  = computeSearchDirection(g, H, δ, γ_2, r, 0, print_level)
				temp_success = success_find_interval && success_bisection
				return temp_success, δ_m, d_k, total_number_factorizations
			catch e
				@error e
			end
		end

	    norm_d_k_squared_without_τ_squared = 0.0

	    for i in 1:length(eigenvaluesVector)
	        if eigenvaluesVector[i] != minimumEigenValue
	            norm_d_k_squared_without_τ_squared = norm_d_k_squared_without_τ_squared + ((Q[:, i]' * g) ^ 2 / (eigenvaluesVector[i] + δ) ^ 2)
	        end
	    end

	    norm_d_k_squared = r ^ 2
		if norm_d_k_squared < norm_d_k_squared_without_τ_squared && print_level >= 1
			println("norm_d_k_squared is $norm_d_k_squared and norm_d_k_squared_without_τ_squared is $norm_d_k_squared_without_τ_squared.")
		end

		if norm_d_k_squared < norm_d_k_squared_without_τ_squared
			if less_than_radius
				if print_level >= 1
					println("HAD CASE LOGIC: δ, d_k and r are $δ, $temp_d_norm, and $r.")
				end
				return true, δ, temp_d, 0
			end
			if print_level >= 1
				println("minimumEigenValue is $minimumEigenValue")
				println("r is $r")
				println("g is $g")
				H_matrix = Matrix(H)
				println("H is $H_matrix")
			end
			return false, δ, zeros(length(g)), 0
		end

	    τ = sqrt(norm_d_k_squared - norm_d_k_squared_without_τ_squared)
	    d_k = τ .* z

	    for i in 1:length(eigenvaluesVector)
	        if eigenvaluesVector[i] != minimumEigenValue
	            d_k = d_k .- ((Q[:, i]' * g) / (eigenvaluesVector[i] + δ)) * Q[:, i]
	        end
	    end
		temp_norm_d_k = norm(d_k, 2)
		if print_level >= 1
			println("HAD CASE LOGIC: δ, d_k and r are $δ, $temp_norm_d_k, and $r.")
		end
	    return true, δ, d_k, 0
	catch e
		@show e
		if print_level >= 1
			println("minimumEigenValue is $minimumEigenValue")
			println("r is $r")
			println("g is $g")
			H_matrix = Matrix(H)
			println("H is $H_matrix")
		end
		return false, δ, zeros(length(g)), 0
	end

end
