function populate_base_model!(
    state::CurrentState,
    form::DMIPFormulation,
    node::Node,
    config::AlgorithmConfig,
)
    if !state.model_invalidated
        return nothing
    end
    empty!(state.constraint_state)
    model = config.lp_solver_factory(state, config)::Gurobi.Optimizer
    for i in 1:num_variables(form)
        bound = form.feasible_region.bounds[i]
        l, u = bound.lower, bound.upper
        if form.integrality[i] isa ZO
            l = max(0, l)
            u = min(1, u)
        end
        # Cache the above updates in formulation. Even better,
        # batch add variables.
        vi, ci = MOI.add_constrained_variable(model, IN(l, u))
        push!(state.constraint_state.base_var_constrs, ci)
    end
    for lt_constr in form.feasible_region.lt_constrs
        ci = MOIU.normalize_and_add_constraint(model, lt_constr.f, lt_constr.s)
        push!(state.constraint_state.base_lt_constrs, ci)
    end
    for gt_constr in form.feasible_region.gt_constrs
        ci = MOIU.normalize_and_add_constraint(model, gt_constr.f, gt_constr.s)
        push!(state.constraint_state.base_gt_constrs, ci)
    end
    for et_constr in form.feasible_region.et_constrs
        ci = MOIU.normalize_and_add_constraint(model, et_constr.f, et_constr.s)
        push!(state.constraint_state.base_et_constrs, ci)
    end
    # TODO: Test this once it does something...
    for formulater in form.disjunction_formulaters
        apply!(model, formulator, node)
    end
    MOI.set(model, MOI.ObjectiveFunction{SAF}(), form.obj)
    MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    state.gurobi_model = model
    state.model_invalidated = false
    state.total_model_builds += 1
    return nothing
end

function apply_branchings!(
    model::MOI.AbstractOptimizer,
    state::CurrentState,
    node::Node,
)
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
    num_branch_lt_constrs = length(state.constraint_state.branch_lt_constrs)
    for (i, ac) in enumerate(node.lt_constrs)
        # Invariant: The constraints are added in order. If we're adding
        # constraint i attached at this node, and length of branch_lt_constrs
        #  is no less than i, then we've already added it, so can skip.
        if i > num_branch_lt_constrs
            ci = MOIU.normalize_and_add_constraint(model, ac.f, ac.s)
            push!(state.constraint_state.branch_lt_constrs, ci)
        end
    end
    num_branch_gt_constrs = length(state.constraint_state.branch_gt_constrs)
    for (i, ac) in enumerate(node.gt_constrs)
        # Invariant: The constraints are added in order. If we're adding
        # constraint i attached at this node, and length of branch_gt_constrs
        #  is no less than i, then we've already added it, so can skip.
        if i > num_branch_gt_constrs
            ci = MOIU.normalize_and_add_constraint(model, ac.f, ac.s)
            push!(state.constraint_state.branch_gt_constrs, ci)
        end
    end
    return nothing
end

function _get_lp_solution!(model::MOI.AbstractOptimizer)
    nvars = MOI.get(model, MOI.NumberOfVariables())
    x = Vector{Float64}(undef, nvars)
    for v in MOI.get(model, MOI.ListOfVariableIndices())
        x[v.value] = MOI.get(model, MOI.VariablePrimal(), v)
    end
    return x
end

function get_basis(state::CurrentState)::Basis
    basis = Basis()
    for ci in state.constraint_state.base_var_constrs
        push!(
            basis.base_var_constrs,
            MOI.get(state.gurobi_model, MOI.ConstraintBasisStatus(), ci),
        )
    end
    for ci in state.constraint_state.base_lt_constrs
        push!(
            basis.base_lt_constrs,
            MOI.get(state.gurobi_model, MOI.ConstraintBasisStatus(), ci),
        )
    end
    for ci in state.constraint_state.base_gt_constrs
        push!(
            basis.base_gt_constrs,
            MOI.get(state.gurobi_model, MOI.ConstraintBasisStatus(), ci),
        )
    end
    for ci in state.constraint_state.base_et_constrs
        push!(
            basis.base_et_constrs,
            MOI.get(state.gurobi_model, MOI.ConstraintBasisStatus(), ci),
        )
    end
    for ci in state.constraint_state.branch_lt_constrs
        push!(
            basis.branch_lt_constrs,
            MOI.get(state.gurobi_model, MOI.ConstraintBasisStatus(), ci),
        )
    end
    for ci in state.constraint_state.branch_gt_constrs
        push!(
            basis.branch_gt_constrs,
            MOI.get(state.gurobi_model, MOI.ConstraintBasisStatus(), ci),
        )
    end
    return basis
end

function set_basis_if_available!(
    model::MOI.AbstractOptimizer,
    state::CurrentState,
    node::Node,
)
    if haskey(state.warm_starts, node)
        _set_basis!(model, state.constraint_state, state.warm_starts[node])
        state.total_warm_starts += 1
    end
    return nothing
end

function _set_basis!(
    model::MOI.AbstractOptimizer,
    constraint_state::ConstraintState,
    basis::Basis,
)::Nothing
    # TODO: Check that basis is, in fact, a basis after modification
    @debug "Basis is being set ($(length(basis)) elements)"
    if isempty(basis.base_var_constrs) &&
       isempty(basis.base_lt_constrs) &&
       isempty(basis.base_gt_constrs) &&
       isempty(basis.base_et_constrs) &&
       isempty(basis.branch_lt_constrs) &&
       isempty(basis.branch_gt_constrs)
        throw(ArgumentError("You are attempting to set an empty basis."))
    end
    for (i, bs) in enumerate(basis.base_var_constrs)
        ci = constraint_state.base_var_constrs[i]
        MOI.set(model, MOI.ConstraintBasisStatus(), ci, bs)
    end
    for (i, bs) in enumerate(basis.base_lt_constrs)
        ci = constraint_state.base_lt_constrs[i]
        MOI.set(model, MOI.ConstraintBasisStatus(), ci, bs)
    end
    for (i, bs) in enumerate(basis.base_gt_constrs)
        ci = constraint_state.base_gt_constrs[i]
        MOI.set(model, MOI.ConstraintBasisStatus(), ci, bs)
    end
    for (i, bs) in enumerate(basis.base_et_constrs)
        ci = constraint_state.base_et_constrs[i]
        MOI.set(model, MOI.ConstraintBasisStatus(), ci, bs)
    end
    for (i, bs) in enumerate(basis.branch_lt_constrs)
        ci = constraint_state.branch_lt_constrs[i]
        MOI.set(model, MOI.ConstraintBasisStatus(), ci, bs)
    end
    for (i, bs) in enumerate(basis.branch_gt_constrs)
        ci = constraint_state.branch_gt_constrs[i]
        MOI.set(model, MOI.ConstraintBasisStatus(), ci, bs)
    end
    return nothing
end
