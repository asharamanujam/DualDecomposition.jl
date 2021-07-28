using JuMP, GLPK, DualDecomposition
#using Plasmo

const DD = DualDecomposition

"""
a: interest rate
π: unit stock price
ρ: unit dividend price


K: number of stages
L: number of stock types
2^L scenarios in each stage
2^L^(K-1)=16 scenarios in total
ρ = 0.05 * π
bank: interest rate 0.01
stock1: 1.03 or 0.97
stock2: 1.06 or 0.94
...

b_k: initial asset (if k=1) and income (else)
B_k: money in bank
x_{k,l}: number of stocks to buy/sell (integer)
y_{k,l}: total stocks 

deterministic model:

    max     B_K+∑_{l=1}^{L}π_{K,l}y_{K,l}

    s.t.    B_1+∑_{l=1}^{L}π_{1,l}x_{1,l} = b_1

            b_k+(1+a)B_{k-1}+∑_{l=1}^{L}ρ_{k,l}y_{k-1,l} = B_k+∑_{l=1}^{L}π_{k,l}x_{k,l}, ∀ k=2,…,K
    
            y_{1,l} = x_{1,l}, ∀ l=1,…,L
    
            y_{k-1,l}+x_{k,l} = y_{k,l}, ∀ k=2,…,K, l=1,…,L
    
            x_{k,l} ∈ ℤ , ∀ k=1,…,K, l=1,…,L
    
            y_{k,l} ≥ 0, ∀ k=1,…,K, l=1,…,L
    
            B_k ≥ 0, ∀ k=1,…,K.
"""
const K = 3
const L = 2
const a = 0.01
const b_init = 100  # initial capital
const b_in = 30   # income

"""
# iteratively add nodes
# root nde
function create_nodes!(graph::Plasmo.OptiGraph)
    nd = DD.add_node!(graph, ones(L))

    #subproblem formulation
    @variable(nd, x[l=1:L], Int)
    @variable(nd, y[l=1:L] >= 0)
    @variable(nd, B >= 0)
    π = nd.ext[:ξ]
    @constraints(nd, 
        begin
            B + sum( π[l] * x[l] for l in 1:L) == b_init
            [l=1:L], y[l] - x[l] == 0 
        end
    )
    @objective(nd, Max, nd.ext[:p] * 0)

    create_nodes!(graph, nd)
end
# child nodes
function create_nodes!(graph::Plasmo.OptiGraph, pt::Plasmo.OptiNode)
    for scenario = 1:2^L
        prob = 1/2^L
        ξ = get_realization(pt.ext[:ξ], scenario)
        nd = DD.add_node!(graph, ξ, pt, prob)

        #subproblem formulation
        @variable(nd, x[l=1:L], Int)
        @variable(nd, y[l=1:L] >= 0)
        @variable(nd, B >= 0)
        @variable(nd, y_[l=1:L] >= 0)
        @variable(nd, B_ >= 0)
        π = nd.ext[:ξ]
        ρ = pt.ext[:ξ] * 0.05
        @constraint(nd, B + sum( π[l] * x[l] - ρ[l] * y_[l] for l in 1:L) - (1+a) * B_ == b_in)
        @constraint(nd, [l=1:L], y[l] - x[l] - y_[l] == 0)

        @linkconstraint(graph, [l=1:L], nd[:y_][l] == pt[:y][l])
        @linkconstraint(graph, nd[:B_] == pt[:B])

        if nd.ext[:stage] < K
            @objective(nd, Max, nd.ext[:p] * 0)
            create_nodes!(graph, nd)
        else
            @constraint(nd, [l=1:L], x[l] == 0)
            @objective(nd, Max, nd.ext[:p] * (B + sum( π[l] * y[l] for l in 1:L )))
        end
    end
end

# construct realization event
function get_realization(ξ::Array{Float64,1}, scenario::Int)::Array{Float64,1}
    ret = ones(L)
    multipliers = digits(scenario - 1, base=2, pad=L)*2 - ones(L)
    for l = 1:L
        ret[l] = ξ[l] * (1 + multipliers[l] * l * 0.03)
    end
    return ret
end

# create graph
graph = Plasmo.OptiGraph()
create_nodes!(graph)
set_optimizer(graph,GLPK.Optimizer)
optimize!(graph)
println(objective_value(graph))
"""

# iteratively add nodes
# root node
function create_nodes()
    ξ = Dict{Symbol, Float64}(:π => ones(L))
    tree = DD.Tree(ξ)

    #subproblem formulation
    function subproblem_builder(tree::DD.SubTree, node::DD.SubTreeNode)
        mdl = tree.model
        x = @variable(mdl, x[l=1:L], Int, base_name="n1_x")

        y = @variable(mdl, y[l=1:L] >= 0, base_name="n1_y")
        DD.set_output_variable!(node, :y, y)

        B = @variable(mdl, B >= 0, base_name="n1_B")
        DD.set_output_variable!(node, :B, B)

        π = DD.get_scenario(node)[:π]
        @constraints(mdl, 
            begin
                B + sum( π[l] * x[l] for l in 1:L) == b_init
                [l=1:L], y[l] - x[l] == 0 
            end
        )
        DD.set_stage_objective(node, 0)

        JuMP.unregister(mdl, x)
        JuMP.unregister(mdl, y)
        JuMP.unregister(mdl, B)
    end

    DD.set_stage_builder!(tree, 1, subproblem_builder)

    create_nodes!(tree, 1)
end

# child nodes
function create_nodes!(tree::DD.Tree, pt::Int)
    for scenario = 1:2^L
        prob = 1/2^L
        π = get_realization(DD.get_scenario(tree, pt)[:π], scenario)
        ξ = Dict{Symbol, Float64}(:π => π)
        id = DD.add_child!(tree, pt, ξ, prob)

        #subproblem formulation
        function subproblem_builder(tree::DD.SubTree, node::DD.SubTreeNode)
            mdl = tree.model
            id = DD.get_id(node)
            x = @variable(mdl, x[l=1:L], Int, base_name = "n$(id)_x")

            y = @variable(mdl, y[l=1:L] >= 0, base_name = "n$(id)_y")
            DD.set_output_variable!(node, :y, y)

            B = @variable(mdl, B >= 0, base_name = "n$(id)_B")
            DD.set_output_variable!(node, :B, B)

            y_ = @variable(mdl, y_[l=1:L] >= 0, base_name = "n$(id)_y_")
            DD.set_input_variable!(node, :y, y_)

            B_ = @variable(mdl, B_ >= 0, base_name = "n$(id)_B_")
            DD.set_input_variable!(node, :B, B_)

            π = DD.get_scenario(node)[:π]
            ρ = DD.get_scenario(tree, pt)[:π] * 0.05
            @constraint(mdl, B + sum( π[l] * x[l] - ρ[l] * y_[l] for l in 1:L) - (1+a) * B_ == b_in)
            @constraint(mdl, [l=1:L], y[l] - x[l] - y_[l] == 0)

            if DD.get_stage(node) < K
                DD.set_stage_objective(node, 0)
            else
                @constraint(nd, [l=1:L], x[l] == 0)
                DD.set_stage_objective(B + sum( π[l] * y[l] for l in 1:L ))
            end
            JuMP.unregister(mdl, x)
            JuMP.unregister(mdl, y)
            JuMP.unregister(mdl, B)
            JuMP.unregister(mdl, y_)
            JuMP.unregister(mdl, B_)
        end

        DD.set_stage_builder!(tree, id, subproblem_builder)

        create_nodes!(tree, id)
    end
end

# construct realization event
function get_realization(ξ::Array{Float64,1}, scenario::Int)::Array{Float64,1}
    ret = ones(L)
    multipliers = digits(scenario - 1, base=2, pad=L)*2 - ones(L)
    for l = 1:L
        ret[l] = ξ[l] * (1 + multipliers[l] * l * 0.03)
    end
    return ret
end