# NOTE: for documentation on how this stuff works see docs/dev/compiler.md
# --------- #
# Utilities #
# --------- #

_is_not_line(x) = true
_is_not_line(::LineNumberNode) = false
_is_not_line(ex::Expr) = ex.head != :line

const DISPATCH_ARG = gensym(:dispatch)

_filter_lines!(x) = x

function _filter_lines!(ex::Expr)
    filter!(_is_not_line, ex.args)  # filter these args
    map(_filter_lines!, ex.args)    # then map over any nested Expr
    ex
end

_filter_lines(ex::Expr) = _filter_lines!(deepcopy(ex))

"Convert lhs = rhs to rhs - lhs. Used in computation of derivatives"
_rhs_only(ex::Expr) =
    ex.head == :(=) ? Expr(:call, :(-), ex.args[2], ex.args[1]) : ex

function _unpack_expr(names::Vector, rhs::Symbol)
    _args = [:($(normalize(names[i])) = Dolang._unpack_var($rhs, $i))
             for i in 1:length(names)]
    out = Expr(:block); out.args = _args; out
end

function _unpack_expr(d::Associative, _discard)
    _args = vcat([_unpack_expr(v, k) for (k, v) in d]...)
    out = Expr(:block); out.args = _args; out
end

"returns an expression `:(lhs[i] = rhs)`"
_assign_var_expr(lhs, rhs, i) = :(Dolang._assign_var($lhs, $rhs, $i))

# ----------------- #
# Expression Blocks #
# ----------------- #

"Expression that allocates memory for variable `out` in non-mutating version"
allocate_block(ff::FunctionFactory, ::TDer{0}=Der{0}) =
    :(out = Dolang._allocate_out(eltype($(arg_names(ff)[1])), $(length(ff.eqs)),
                                 $(arg_names(ff)...)))

"Expression that checks the size of `out` in mutating version"
function sizecheck_block(ff::FunctionFactory, ::TDer{0}=Der{0})
    ex = quote
        expected_size = Dolang._output_size($(length(ff.eqs)), $(arg_names(ff)...))
        if size(out) != expected_size
            msg = "Expected out to be size $(expected_size), found $(size(out))"
            throw(DimensionMismatch(msg))
        end
    end
    _filter_lines!(ex)
    ex
end

param_block(ff::FunctionFactory, vec::Symbol=:p) =
    _unpack_expr(ff.params, vec)

arg_block(ff::FunctionFactory, vec::Symbol=:V) = _unpack_expr(ff.args, vec)

"Evaluates main expressions in a function group and fills `out` with results"
function equation_block end

# TODO: this loop is a hack to get around a method ambiguity error caused
#       by the version of this function for arbitrary order derivative for
#       FlatArg
for T in (FlatArgs, GroupedArgs)
    @eval function equation_block{T<:$(T)}(ff::FunctionFactory{T}, ::TDer{0}=Der{0})
        n_expr = length(ff.eqs)
        func_block = Expr(:block)

        if isempty(ff.targets)
            # no targets, just set out = parsed_expr
            assignments = map((rhs, i) -> _assign_var_expr(:out, rhs, i),
                              ff.eqs, 1:n_expr)
            func_block.args = assignments
        else
            # otherwise, need to parse the targets, evaluate them, and then set
            # elements of out equal to the targets
            assignments = map((rhs, i) -> _assign_var_expr(:out, rhs, i),
                              ff.targets, 1:n_expr)
            func_block.args = vcat(ff.eqs, assignments)
        end

        return func_block
    end
end

function body_block{n}(ff::FunctionFactory, ::TDer{n})
    _args = [param_block(ff), arg_block(ff), equation_block(ff, Der{n}),
             :(return out)]
    out = Expr(:block); out.args = _args; out
end

# ------------------- #
# Function Signatures #
# ------------------- #

arg_names{T1<:FlatArgs}(::FunctionFactory{T1}) = [:V]

# WARNING: This function will only work in a reliable way if the keys are
#          guaranteed to come out in the same order each time. To ensure this
#          we reccomend using an instance of `OrderedDict` from the
#          DataStructures.jl package instead of a `Dict` from Base.
arg_names{T1<:GroupedArgs}(ff::FunctionFactory{T1}) =
    collect(keys(ff.args))::Vector{Symbol}

param_names{T1,T2<:FlatParams}(::FunctionFactory{T1,T2}) = [:p]

param_names{T1,T2<:GroupedParams}(ff::FunctionFactory{T1,T2}) =
    collect(keys(ff.params))::Vector{Symbol}

_extra_args{n}(ff::FunctionFactory, d::TDer{n}) =
    ff.dispatch == SkipArg ? Any[:(::Dolang.TDer{$n})] :
                                [:(::Dolang.TDer{$n}),
                                 :($(DISPATCH_ARG)::$(ff.dispatch))]

function signature{n,T1<:FlatArgs}(ff::FunctionFactory{T1}, d::TDer{n}=Der{0})
    Expr(
        :call,
        ff.funname,
        _extra_args(ff, d)...,
        :(V::AbstractVector),
        param_names(ff)...
    )
end

function signature{n,T1<:GroupedArgs}(ff::FunctionFactory{T1}, d::TDer{n}=Der{0})
    Expr(
        :call,
        ff.funname,
        _extra_args(ff, d)...,
        [:($(k)::AbstractVector) for k in keys(ff.args)]...,
        param_names(ff)...
    )
end

"Method signature for mutating version of the function"
function signature!{n}(ff::FunctionFactory, d::TDer{n}=Der{0})
    sig = signature(ff, d)

    # convert name to `!` version and insert `out` as first argument
    sig.args[1] = Symbol(sig.args[1], "!")
    insert!(sig.args, length(_extra_args(ff, d))+2, :out)
    sig
end

# ---------------- #
# First derivative #
# ---------------- #

# first we need a couple of helper methods

function _jacobian_expr_mat{T<:FlatArgs}(ff::FunctionFactory{T})
    # NOTE: I'm starting with the easy version, where I just differentiate
    #       with respect to all arguments in the order they were given. It
    #       would be better if I went though `ff.incidence.by_var` and only
    #       made columns for variables that appear in the equations
    args = ff.args
    neq = length(ff.eqs)
    nvar = nargs(ff)

    exprs = Array{Union{Symbol,Expr,Number}}(neq, nvar)
    fill!(exprs, 0)

    non_zero = 0
    for i_eq = 1:neq
        eq = _rhs_only(ff.eqs[i_eq])
        eq_prepped = prep_deriv(eq)
        eq_incidence = ff.incidence.by_eq[i_eq]

        for i_var in 1:nvar
            v, shift = arg_name_time(args[i_var])

            if haskey(eq_incidence, v) && in(shift, eq_incidence[v])
                non_zero += 1
                my_deriv = deriv(eq_prepped, normalize(args[i_var]))
                exprs[i_eq, i_var] = post_deriv(my_deriv)
            end
        end
    end
    exprs, non_zero
end

_output_size(ff::FunctionFactory, ::TDer{1}) =
    (length(ff.eqs), nargs(ff))

# Now fill in FunctionFactory API
function allocate_block(ff::FunctionFactory, d::TDer{1})
    expected_size = _output_size(ff, d)
    :(out = zeros(Float64, $(expected_size)))
end

function sizecheck_block(ff::FunctionFactory, d::TDer{1})
    expected_size = _output_size(ff, d)
    ex = quote
        if size(out) != $expected_size
            msg = "Expected out to be size $($(expected_size)), found $(size(out))"
            throw(DimensionMismatch(msg))
        end
        # populate with zeros, because we assume everything is zeroed and
        # only fill in non-zero elements
        fill!(out, zero(eltype(out)))
    end
    _filter_lines!(ex)
    ex
end

function equation_block{T<:FlatArgs}(ff::FunctionFactory{T}, ::TDer{1})
    expr_mat, non_zero = _jacobian_expr_mat(ff)
    neq = size(expr_mat, 1)
    nvar = size(expr_mat, 2)

    # construct expressions that define the body of this function.
    # we need neq*nvar of them
    expr_args = Array{Expr}(non_zero)

    # To do this we use linear indexing tricks to access `out` and `expr_mat`.
    # Note the offset on the index to expr_args also (needed because allocating)
    # is the first expression in the block
    ix = 0
    for ii in eachindex(expr_mat)
        if expr_mat[ii] != 0
            expr_args[ix+=1] = :(out[$(ii)] = $(expr_mat[ii]))
        end
    end

    out = Expr(:block)

    # when we populated expr_args we skipped terms that were equal to zero.
    # here we trim expr_args to be the length of the number of non-zero terms
    out.args = expr_args[1:ix]
    out
end

# ------------------------ #
# Higher order derivatives #
# ------------------------ #

# NOTE: allocations for the higher order derivatiaves are done in in the
#       equation_block because it requires us to know the number of non-zero
#       derivative terms, which we only know after we have constructed them.
allocate_block{D}(ff::FunctionFactory, ::TDer{D}) = nothing
sizecheck_block{D}(ff::FunctionFactory, ::TDer{D}) = nothing

function make_deriv_loop(i::Int, der_order::Int)
    i < 1 && error("i must be positive")

    # define symbols to be used in this loop
    i_sym = Symbol("iv_", i)
    var_sym = Symbol("v_", i)
    shift_sym = Symbol("shift_", i)
    diff_sym = Symbol("diff_v_", i)

    # build loop range. Will be 1:nvar if i == 1 and iv_{i-1}:nvar if i > 1
    if i == 1
        loop_range = :($i_sym = 1:nvar)
    else
        prev_i_sym = Symbol("iv_", i-1)
        loop_range = :($i_sym = $prev_i_sym:nvar)
    end

    # build _inner_part of the loop body. This will include the actual derivation
    # if i == der_order or it will differentiate the current expression wrt
    # the ith variable and recursively call this function with i = i+1
    if i == der_order
        sym_to_diff = i == 1 ? :eq_prepped : Symbol("diff_v_", i-1)
        index_tuple = Expr(:tuple, [Symbol("iv_", j) for j in 1:i]...)
        inner_loop_guts = quote
            $diff_sym = deriv($sym_to_diff, normalize(ff.args[$i_sym]))

            # might still be zero if terms were independent
            if $diff_sym != 0
                push!(eq_terms, ($index_tuple, post_deriv($diff_sym)))
            end
        end
    else
        inner_loop_guts = Expr(
            :block,
            :($diff_sym = deriv(eq_prepped, normalize(ff.args[$i_sym]))),
            make_deriv_loop(i+1, der_order)
        )
    end

    # build loop body. 3 steps:
    # 1. extract variable/time shift
    # 2. Check to make sure the variable appears at the time shift in the eq
    # 3. put in the inner_loop_guts we created above
    body = quote
        $var_sym, $shift_sym = arg_name_time(ff.args[$i_sym])
        if haskey(eq_incidence, $var_sym) && in($shift_sym, eq_incidence[$var_sym])
            $inner_loop_guts
        end
    end

    # put the loop range and body together
    Expr(:for, loop_range, body)
end

# code to generate derivative expressions. This could be put in the body of
# the `@generated` function, but that makes it hard for me to see the code
# that is generated, so I make it a standalone function.
@compat function derivative_exprs_impl{T<:FlatArgs,D}(::Type{<:FunctionFactory{T}}, ::TDer{D})
    # first, build the body of loops that differentiate an equation.
    body = make_deriv_loop(1, D)

    quote

        # get counter variables
        neq = length(ff.eqs)
        nvar = nargs(ff)

        # instantiate the array that will hold the output
        terms = Vector{Vector{Tuple{NTuple{$D,Int},Union{Expr,Symbol,Number}}}}(0)

        # loop over equations and call the body we built above to populate
        # terms
        for i_eq in 1:neq
            eq_terms = Vector{Tuple{NTuple{$D,Int},Union{Expr,Symbol,Number}}}(0)
            ex = _rhs_only(ff.eqs[i_eq])
            eq_prepped = prep_deriv(ex)
            eq_incidence = ff.incidence.by_eq[i_eq]

            $body

            push!(terms, eq_terms)
        end

        # return what we built
        return terms
    end
end

@generated function derivative_exprs{T<:FlatArgs,D}(ff::FunctionFactory{T}, ::TDer{D})
    derivative_exprs_impl(ff, Der{D})
end

function equation_block{T<:FlatArgs,D}(ff::FunctionFactory{T}, ::TDer{D})
    Expr(:(=), :out, derivative_exprs(ff, Der{D}))
end

# Ordering of hessian is H[eq, (v1,v2)]
function equation_block{T<:FlatArgs}(ff::FunctionFactory{T}, ::TDer{2})
    exprs = derivative_exprs(ff, Der{2})
    n_expr = length(exprs)
    nvar = nargs(ff)
    n_eqs = length(ff.eqs)

    n_terms = 0
    val_ix = 0
    for i_eq in 1:n_eqs, e in exprs[i_eq]
        # if indices are the same, term is for (v[i], v[i]), so it only appears
        # one time. Otherwise, we need to account for symmetry and have two
        # terms
        n_terms += e[1][1] == e[1][2] ? 1 : 2
        val_ix += 1
    end

    # create expressions that fill in the correct elements of i, j, v based
    # on the data in `vals` and the indices in `exprs`
    val_exprs = Union{Expr,Number,Symbol}[]
    pop_exprs = Array{Expr}(n_terms)
    ix = 0
    for (i_eq, stuff) in enumerate(exprs)
        for ((i_v1, i_v2), _the_expr) in stuff
            # we definitely need to fill the `i_eq, (i_v1, i_v2)` element
            ix += 1

            # create expressions that define `_val_eq_i1_i2`, which holds the
            # numerical value associated with the `i`th expression. WE do this
            # to avoid computing symmetric elements more than once.
            val_sym = Symbol("_val_$(i_eq)_$(i_v1)_$(i_v2)")
            push!(val_exprs, Expr(:(=), val_sym, _the_expr))

            # value of j
            j = sub2ind((nvar, nvar), i_v1, i_v2)
            pop_exprs[ix] = Expr(:block,
                :(setindex!(i, $(i_eq), $(ix))),
                :(setindex!(j, $(j), $(ix))),
                :(setindex!(v, $(val_sym), $(ix)))
            )

            if i_v1 != i_v2
                # here we also need to fill the symmetric off diagonal element
                ix += 1
                j2 = sub2ind((nvar, nvar), i_v2, i_v1)
                pop_exprs[ix] = Expr(:block,
                    :(setindex!(i, $(i_eq), $(ix))),
                    :(setindex!(j, $(j2), $(ix))),
                    :(setindex!(v, $(val_sym), $(ix)))
                )
            end
        end
    end

    # gather these assignments into a block
    populate = Expr(:block)
    populate.args = pop_exprs

    vals = Expr(:block)
    vals.args = val_exprs

    # finally construct the whole blocks
    out = quote
        i = Array{Int}($(n_terms))
        j = Array{Int}($(n_terms))
        v = Array{Float64}($(n_terms))

        # include vals
        $vals

        # populate i, j, v with vals
        $populate

        # construct sparse matrix from i, j, v and return it
        return sparse(i, j, v, $(length(ff.eqs)), $(nvar*nvar))
    end

    _filter_lines!(out)

end

# -------------------------- #
# Putting functions together #
# -------------------------- #

func_body{n}(ff::FunctionFactory, d::TDer{n}) =
    Expr(:block, allocate_block(ff, d), body_block(ff, d))

func_body!{n}(ff::FunctionFactory, d::TDer{n}) =
    Expr(:block, sizecheck_block(ff, d), body_block(ff, d))

function _build_function{n}(ff::FunctionFactory, d::TDer{n},
                            sig_func::Function, body_func::Function)
    Expr(:function, sig_func(ff, d), body_func(ff, d))
end

function _build_function(ff::FunctionFactory, d::TDer{0}, sig_func::Function,
                         body_func::Function)
    body = body_func(ff, d)
    sig = sig_func(ff, d)
    no_der_sig = deepcopy(sig)
    splice!(no_der_sig.args, 2)
    Expr(:block,
         Expr(:function, sig, body),
         Expr(:function, no_der_sig, body)
         )
end

# NOTE: we could easily allocate and then call the mutating version, but we
#       don't do that because then we get overhead for allocating _and_
#       for checking the size of out
"Build allocating version of the method"
build_function{n}(ff::FunctionFactory, d::TDer{n}) =
    _build_function(ff, d, signature, func_body)

"Build non-allocating version of the method"
function build_function! end
for D in [0, 1]
    @eval function build_function!(ff::FunctionFactory, d::TDer{$D})
        _build_function(ff, d, signature!, func_body!)
    end
end

# we don't support non-allocating methods for derivatives above 1
build_function!{D}(ff::FunctionFactory, ::TDer{D}) =
    warn("Non-allocating order $(D) derivatives not supported")


function _build_vectorized_function(ff::FunctionFactory, d::TDer{0},
                                    allocating::Bool)

    sig = allocating ? signature(ff, d) : signature!(ff, d)
    n_args = length(arg_names(ff))
    #= We need to adjust sig.args so that all function args (except der,
    dispatch, and params) have type AbstractMatrix instead of AbstractVector

    These will always be sig.args[end-1-length(arg_names(ff)):end-1]
    =#
    start_ix = length(sig.args) - n_args
    end_ix = length(sig.args) - 1
    for (i, name) in zip(start_ix:end_ix, arg_names(ff))
        sig.args[i] = Expr(:(::), name, :AbstractMatrix)
    end
    sig

    # use signature to figure out how to call non-vectorized version within the
    # loop
    row_i_sig = signature(ff, d)
    row_i_sig.args[2] = :($(d))
    if !allocating
        start_ix -= 1
        end_ix -= 1
    end
    for (i, name) in zip(start_ix:end_ix, arg_names(ff))
        row_i_sig.args[i] = Expr(:call, :view, name, :_row, :(:))
    end

    body = Expr(:block,
        allocating ? allocate_block(ff, d) : sizecheck_block(ff, d),
        :(nrow = size($(arg_names(ff)[1]), 1)),
        Expr(:for, :(_row = 1:nrow),
            Expr(:block,
            :(@inbounds out[_row, :] = $(row_i_sig))
            )
        ),
        :(return out)
    )

    no_der_sig = deepcopy(sig)
    splice!(no_der_sig.args, 2)
    Expr(:block,
         Expr(:function, sig, body),
         Expr(:function, no_der_sig, body)
         )
end

build_vectorized_function{n}(ff::FunctionFactory, d::TDer{n}) =
    _build_vectorized_function(ff, d, true)

build_vectorized_function!{n}(ff::FunctionFactory, d::TDer{n}) =
    _build_vectorized_function(ff, d, false)

# -------- #
# User API #
# -------- #
# This is the main method that does the work.
function make_method{n}(d::TDer{n}, ff::FunctionFactory; mutating::Bool=true,
                        allocating::Bool=true)

    out = Expr(:block)
    if mutating
        push!(out.args, build_function!(ff, d))
        n == 0 && push!(out.args, build_vectorized_function!(ff, d))
    end
    if allocating
        push!(out.args, build_function(ff, d))
        n == 0 && push!(out.args, build_vectorized_function(ff, d))
    end
    out
end

# accept derivative order(s) as keyword argument
function make_method(ff::FunctionFactory;
                     mutating::Bool=true,
                     allocating::Bool=true,
                     orders=0)
    out = Expr(:block)
    for i in orders
        out_i = make_method(Der{i}, ff; mutating=mutating, allocating=allocating)
        append!(out.args, out_i.args)
    end
    out
end

# Method without `dispatch` argument and with orders as kwarg
function make_method(eqs::Vector{Expr},
                     arguments::ArgType,
                     params::ParamType;
                     targets=Symbol[],
                     defs::Associative=Dict(),
                     funname::Symbol=gensym(:anonymous),
                     mutating::Bool=true,
                     allocating::Bool=true,
                     orders=0)
    ff = FunctionFactory(eqs, arguments, params,
                         targets=targets, defs=defs, funname=funname)

    make_method(ff; mutating=mutating, allocating=allocating, orders=orders)
end

# Method with `dispatch` argument and with orders as kwarg
function make_method{T}(::Type{T}, eqs::Vector{Expr},
                        arguments::ArgType,
                        params::ParamType;
                        targets=Symbol[],
                        defs::Associative=Dict(),
                        funname::Symbol=gensym(:anonymous),
                        mutating::Bool=true,
                        allocating::Bool=true, orders=0)
    ff = FunctionFactory(T, eqs, arguments, params,
                         targets=targets, defs=defs, funname=funname)

    make_method(ff; mutating=mutating, allocating=allocating, orders=orders)
end


function make_function(
        eqs::Vector{Expr}, variables::AbstractVector,
        to_diff::AbstractVector=1:length(variables);
        dispatch::DataType=SkipArg,
        targets=Symbol[],
        orders::AbstractVector{Int}=[0, 1],
        name::Symbol=:anon, allocating::Bool=true
    )

    args = variables[to_diff]
    not_to_diff = setdiff(1:length(variables), to_diff)
    params = variables[not_to_diff]

    ff = FunctionFactory(
        dispatch, eqs, args, params; targets=targets, funname=name
    )

    make_method(ff; allocating=allocating, orders=orders)

end
