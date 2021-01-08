function build_base_model(
    form::DMIPFormulation,
    state::CurrentState,
    node::Node,
    config::AlgorithmConfig,
    hot_start_model::Gurobi.Optimizer,
)
    # We assume that the model can be reused from the parent with only
    # changes to the variable bounds.
    # TODO: Revisit the assumption here when the formulation is
    # changing in the tree.
    # TODO: Unit test this.
    return hot_start_model
end

function build_base_model(
    form::DMIPFormulation,
    state::CurrentState,
    node::Node,
    config::AlgorithmConfig,
    hot_start_model::Nothing,
)
    model = config.lp_solver_factory(state, config)::Gurobi.Optimizer
    for i in 1:num_variables(form)
        bound = form.base_form.feasible_region.bounds[i]
        l, u = bound.lower, bound.upper
        if form.integrality[i] isa ZO
            l = max(0, l)
            u = min(1, u)
        end
        # Cache the above updates in formulation. Even better,
        # batch add variables.
        MOI.add_constrained_variable(model, IN(l, u))
    end
    for lt_constr in form.base_form.feasible_region.lt_constrs
        MOI.add_constraint(model, lt_constr.f, lt_constr.s)
    end
    for gt_constr in form.base_form.feasible_region.gt_constrs
        MOI.add_constraint(model, gt_constr.f, gt_constr.s)
    end
    for et_constr in form.base_form.feasible_region.et_constrs
        MOI.add_constraint(model, et_constr.f, et_constr.s)
    end
    # TODO: Test this once it does something...
    for formulater in form.disjunction_formulaters
        apply!(model, formulator, node)
    end
    MOI.set(model, MOI.ObjectiveFunction{SAF}(), form.base_form.obj)
    MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    return model
end

function update_node_bounds!(model::MOI.AbstractOptimizer, node::Node)
    for (vi, lb) in node.lb_diff
        ci = CI{SV,IN}(vi.value)
        interval = MOI.get(model, MOI.ConstraintSet(), ci)
        # @assert lb >= interval.upper
        new_interval = IN(lb, interval.upper)
        MOI.set(model, MOI.ConstraintSet(), ci, new_interval)
    end
    for (vi, ub) in node.ub_diff
        ci = CI{SV,IN}(vi.value)
        interval = MOI.get(model, MOI.ConstraintSet(), ci)
        # @assert ub <= interval.upper
        new_interval = IN(interval.lower, ub)
        MOI.set(model, MOI.ConstraintSet(), ci, new_interval)
    end
    return nothing
end

function _fill_solution!(x::Vector{Float64}, model::MOI.AbstractOptimizer)
    for v in MOI.get(model, MOI.ListOfVariableIndices())
        x[v.value] = MOI.get(model, MOI.VariablePrimal(), v)
    end
    return nothing
end

function update_basis!(result::NodeResult, model::MOI.AbstractOptimizer)
    return _update_basis!(get_basis(result), model)
end

function _update_basis!(basis::Basis, model::MOI.AbstractOptimizer)
    # TODO: Cache ListOfConstraints and ListOfConstraintIndices. This is a
    # (surprising?) bottleneck, taking >50% of time in this function.
    # One idea would be to make sure basis keys remain in sync with constraints
    # in model, and then this function could just loop through keys(basis).
    for (F, S) in MOI.get(model, MOI.ListOfConstraints())
        for ci in MOI.get(model, MOI.ListOfConstraintIndices{F,S}())
            basis[ci] = MOI.get(model, MOI.ConstraintBasisStatus(), ci)
        end
    end
    return nothing
end

set_basis_if_available!(model::MOI.AbstractOptimizer, ::Nothing) = nothing
function set_basis_if_available!(
    model::MOI.AbstractOptimizer,
    basis::Basis,
)::Nothing
    # TODO: Check that basis is, in fact, a basis after modification
    @debug "Basis is being set ($(length(basis)) elements)"
    if isempty(basis)
        throw(ArgumentError("You are attempting to set an empty basis."))
    end
    for (key, val) in basis
        MOI.set(model, MOI.ConstraintBasisStatus(), key, val)
    end
    return nothing
end
