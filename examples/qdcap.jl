#=
This is a MIQP variant of dcap.jl. See dcap.jl.
=#

using JuDD
using JuMP, Ipopt
using CPLEX
using Compat

function main_dcap(nR::Int, nN::Int, nT::Int, nS::Int, seed::Int=1)

    # Create JuDD instance.
    JuDD.LagrangeDuals(nS)

    Compat.Random.seed!(seed)

    global sR = 1:nR
    global sN = 1:nN
    global sT = 1:nT
    global sS = 1:nS

    ## parameters
    global a = rand(nR, nT) * 5 .+ 5
    global b = rand(nR, nT) * 40 .+ 10
    global c = rand(nR, nN, nT, nS) * 5 .+ 5
    global c0 = rand(nN, nT, nS) * 500 .+ 500
    global d = rand(nN, nT, nS) .+ 0.5
    Pr = ones(nS)/nS

    # Add Lagrange dual problem for each scenario s.
    for s in 1:nS
        JuDD.add_Lagrange_dual_model(s, Pr[s], create_scenario_model)
    end

    # Set nonanticipativity variables as an array of symbols.
    JuDD.set_nonanticipativity_vars(nonanticipativity_vars())

    # Solve the problem with the solver; this solver is for the underlying bundle method.
    JuDD.solve(IpoptSolver(print_level=5), master_alrogithm = :ProximalDualBundle)
end

# This creates a Lagrange dual problem for each scenario s.
function create_scenario_model(s::Int64)

    # construct JuMP.Model
    model = Model(solver=CplexSolver(CPX_PARAM_THREADS=1,CPX_PARAM_SCRIND=0))

    ## 1st stage
    @variable(model, x[i=sR,t=sT] >= 0)
    @variable(model, u[i=sR,t=sT], Bin)
    @variable(model, y[i=sR,j=sN,t=sT], Bin)
    @variable(model, z[j=sN,t=sT], Bin)
    @objective(model, Min,
          sum(a[i,t]*x[i,t]^2 + b[i,t]*u[i,t] for i in sR for t in sT)
        + sum(c[i,j,t,s]*y[i,j,t] for i in sR for j in sN for t in sT)
        + sum(c0[j,t,s]*z[j,t] for j in sN for t in sT))
    @constraint(model, [i=sR,t=sT], x[i,t] - u[i,t] <= 0)
    @constraint(model, [i=sR,t=sT], -sum(x[i,tau] for tau in 1:t) + sum(d[j,t,s]*y[i,j,t] for j in sN) <= 0)
    @constraint(model, [j=sN,t=sT], sum(y[i,j,t] for i in sR) + z[j,t] == 1)

    return model
end

# return the array of nonanticipativity variables
nonanticipativity_vars() = [:x,:u]

main_dcap(2,3,3,20)
