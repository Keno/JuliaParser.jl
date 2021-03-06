# Julia Source Parser
module Parser

using ..Lexer

export parse

typealias CharSymbol Union(Char, Symbol)

type ParseState
    # disable range colon for parsing ternary cond op
    range_colon_enabled::Bool 
    
    # in space sensitvie mode "x -y" is 2 exprs, not subtraction
    space_sensitive::Bool
    
    # treat "end" like a normal symbol, instead of a reserved word 
    inside_vector::Bool 
    
    # treat newline like ordinary whitespace instead of a reserved word
    end_symbol::Bool
    
    # treat newline like ordinary whitespace instead of as a potential separator 
    whitespace_newline::Bool
end

ParseState() = ParseState(true, false, false, false, false)

peek_token(ps::ParseState, ts::TokenStream)    = Lexer.peek_token(ts, ps.whitespace_newline)
next_token(ps::ParseState, ts::TokenStream)    = Lexer.next_token(ts, ps.whitespace_newline)
require_token(ps::ParseState, ts::TokenStream) = Lexer.require_token(ts, ps.whitespace_newline)

with_normal_ops(f::Function, ps::ParseState) = begin
    tmp1 = ps.range_colon_enabled
    tmp2 = ps.space_sensitive
    try
        ps.range_colon_enabled = true
        ps.space_sensitive     = false
        f()
    finally
        ps.range_colon_enabled = tmp1
        ps.space_sensitive = tmp2
    end
end

without_range_colon(f::Function, ps::ParseState) = begin
    tmp = ps.range_colon_enabled
    try
        ps.range_colon_enabled = false
        f()
    finally
        ps.range_colon_enabled = tmp
    end
end 

with_inside_vec(f::Function, ps::ParseState) = begin
    tmp1 = ps.space_sensitive
    tmp2 = ps.inside_vector
    tmp3 = ps.whitespace_newline
    try
        ps.space_sensitive = true
        ps.inside_vector   = true
        ps.whitespace_newline = false
        f()
    finally
        ps.space_sensitive = tmp1
        ps.inside_vector = tmp2
        ps.whitespace_newline = tmp3
    end
end

with_end_symbol(f::Function, ps::ParseState) = begin
    tmp = ps.end_symbol
    try
        ps.end_symbol = true
        f()
    finally
        ps.end_symbol = tmp
    end
end

with_whitespace_newline(f::Function, ps::ParseState) = begin
    tmp = ps.whitespace_newline
    try
        ps.whitespace_newline = true
        f()
    finally
        ps.whitespace_newline = tmp
    end
end

without_whitespace_newline(f::Function, ps::ParseState) = begin
    tmp = ps.whitespace_newline
    try
        ps.whitespace_newline = false
        f()
    finally
        ps.whitespace_newline = tmp
    end
end

with_space_sensitive(f::Function, ps::ParseState) = begin
    tmp1 = ps.space_sensitive
    tmp2 = ps.whitespace_newline
    try
        ps.space_sensitive = true
        ps.whitespace_newline = false
        f()
    finally
        ps.space_sensitive = tmp1
        ps.whitespace_newline = tmp2
    end
end

#TODO: line number nodes
curline(ts::TokenStream)  = 0
filename(ts::TokenStream) = ""

line_number_node(ts) = Expr(:line, curline(ts))
line_number_filename_node(ts::TokenStream) = Expr(:line, curline(ts), filename(ts)) 

# insert line/file for short form function defs,
# otherwise leave alone
function short_form_function_loc(ex, lno)
    if isa(ex, Expr) && ex.head === :(=) && isa(ex.args[1], Expr) && ex.args[1].head === :call
       block = Expr(:block, Expr(:line, lno, ""))
       append!(block.args, ex.args[2:end])
       return Expr(:(=), ex.args[1], block) 
   end
   return ex
end

const sym_do      = symbol("do")
const sym_else    = symbol("else")
const sym_elseif  = symbol("elseif")
const sym_end     = symbol("end")
const sym_else    = symbol("else")
const sym_elseif  = symbol("elseif")
const sym_catch   = symbol("catch")
const sym_finally = symbol("finally")
const sym_squote  = symbol("'")

const EOF = char(-1)

const is_invalid_initial_token = let
    invalid = Set({')', ']', '}', sym_else, sym_elseif, sym_catch, sym_finally}) 
    is_invalid_initial_token(t::Token) = isa(t, CharSymbol) && t in invalid
end

const is_closing_token = let
    closing = Set({',', ')', ']', '}', ';', sym_else, sym_elseif, sym_catch, sym_finally})
    is_closing_token(ps::ParseState, t::Token) = (Lexer.eof(t) ||
                                                   (isa(t, CharSymbol) && t in closing) ||
                                                   (t === sym_end && !ps.end_symbol))
end

is_dict_literal(ex::Expr) = ex.head === :(=>) && length(ex.args) == 2
is_dict_literal(ex) = false

function parse_chain(ps::ParseState, ts::TokenStream, down::Function, op) 
    chain = {down(ps, ts)}
    while true 
        t = peek_token(ps, ts)
        t !== op && return chain
        take_token(ts)
        if (ps.space_sensitive && ts.isspace && 
            (isa(t, Symbol) && t in Lexer.unary_and_binary_ops) &&
            Lexer.peekchar(ts.io) != ' ')
            # here we have "x -y"
            put_back!(ts, t) 
            return chain
        end
        push!(chain, down(ps, ts))
    end
end

# parse left to right chains of certain binary operator
# ex. a + b + c => Expr(:call, :+, a, b, c)
function parse_with_chains(ps::ParseState, ts::TokenStream, down::Function, ops, chain_op) 
    ex = down(ps, ts)
    while true 
        t = peek_token(ps, ts)
        !(t in ops) && return ex
        take_token(ts)
        if (ps.space_sensitive && ts.isspace &&
            (t in Lexer.unary_and_binary_ops) &&
            Lexer.peekchar(ts.io) != ' ')
            # here we have "x -y"
            put_back!(ts, t)
            return ex
        elseif t === chain_op
            ex = Expr(:call, t, ex, parse_chain(ps, ts, down, t)...)
        else
            ex = Expr(:call, t, ex, down(ps, ts))
        end
    end
end

function parse_LtoR(ps::ParseState, ts::TokenStream, down::Function, ops, ex=down(ps, ts))
    while true 
        t  = peek_token(ps, ts)
        if !(t in ops)
            return ex
        end
        take_token(ts)
        if Lexer.is_syntactic_op(t) || t === :(in) || t === :(::)
            ex = Expr(t, ex, down(ps, ts))
        else
            ex = Expr(:call, t, ex, down(ps, ts))
        end
        t = peek_token(ps, ts)
    end
end

function parse_RtoL(ps::ParseState, ts::TokenStream, down::Function, ops, ex=down(ps, ts))
    while true 
        t  = peek_token(ps, ts)
        !(t in ops) && return ex
        take_token(ts)
        if (ps.space_sensitive && ts.isspace &&
            (isa(t, Symbol) && t in Lexer.unary_and_binary_ops) &&
            Lexer.peekchar(ts.io) !== ' ')
            put_back!(ts, t)
            return ex
        elseif Lexer.is_syntactic_op(t)
            return Expr(t, ex, parse_RtoL(ps, ts, down, ops))
        elseif t === :(~)
            args = parse_chain(ps, ts, down, :(~))
            nt   = peek_token(ps, ts)
            if isa(nt, CharSymbol) && nt in ops
                ex = Expr(:macrocall, symbol("@~"), ex)
                append!(ex.args, args[1:end-1])
                push!(ex.args, parse_RtoL(ps, ts, down, ops, args[end]))
                return ex 
            else
                return Expr(:macrocall, symbol("@~"), ex, args...)
            end
        else
            return Expr(:call, t, ex, parse_RtoL(ps, ts, down, ops))
        end
    end
end

function parse_cond(ps::ParseState, ts::TokenStream)
    ex = parse_or(ps, ts)
    if peek_token(ps, ts) === :(?)
        take_token(ts)
        then = without_range_colon(ps) do
            parse_eqs(ps, ts)
        end
        take_token(ts) === :(:) || error("colon expected in \"?\" expression")
        return Expr(:if, ex, then, parse_cond(ps, ts))
    end
    return ex
end

function parse_Nary(ps::ParseState, ts::TokenStream, down::Function, ops, 
                    head::Symbol, closers, allow_empty::Bool)
    t = require_token(ps, ts)
    is_invalid_initial_token(t) && error("unexpected \"$t\"")
    # empty block
    if isa(t, CharSymbol) && t in closers
        return Expr(head)
    end
    local args::Vector{Any}
    # in allow empty mode, skip leading runs of operator
    if allow_empty && isa(t, CharSymbol) && t in ops 
        args = {}
    elseif '\n' in ops
        # line-number must happend before (down s)
        loc  = line_number_node(ts)
        args = {loc, down(ps, ts)}
    else
        args = {down(ps, ts)}
    end
    isfirst = true
    t = peek_token(ps, ts)
    while true
        if !(t in ops)
            if !(Lexer.eof(t) || t === '\n' || ',' in ops || t in closers)
                error("extra token \"$t\" after end of expression")
            end
            if isempty(args) || length(args) >= 2 || !isfirst
                # {} => Expr(:head)
                # {ex1, ex2} => Expr(head, ex1, ex2)
                # (ex1) if operator appeared => Expr(head,ex1) (handles "x;")
                return Expr(head, args...)
            else
                # {ex1} => ex1
                return first(args)
            end
        end
        isfirst = false
        take_token(ts)
        # allow input to end with the operator, as in a;b;
        nt = peek_token(ps, ts) 
        if Lexer.eof(nt) || (isa(nt, CharSymbol) && nt in closers) || 
           (allow_empty && isa(nt, CharSymbol) && nt in ops) ||  
           (length(ops) == 1 && first(ops) === ',' && nt === :(=))
           t = nt
           continue
        elseif '\n' in ops
            push!(args, line_number_node(ts))
            push!(args, down(ps, ts))
            t = peek_token(ps, ts)
        else
            push!(args, down(ps, ts))
            t = peek_token(ps, ts)
        end
    end
end 

# the principal non-terminals follow, in increasing precedence order
function parse_block(ps::ParseState, ts::TokenStream)
    parse_Nary(ps, ts, parse_eq, ('\n', ';'), :block,
               (sym_end, sym_else, sym_elseif, sym_catch, sym_finally), true)
end

# for sequenced eval inside expressions, e.g. (a;b, c;d)
function parse_stmts_within_expr(ps::ParseState, ts::TokenStream)
    parse_Nary(ps, ts, parse_eqs, (';',), :block, (',', ')'), true)
end

#; at the top level produces a sequence of top level expressions
function parse_stmts(ps::ParseState, ts::TokenStream)
    ex = parse_Nary(ps, ts, parse_eq, (';',), :toplevel, ('\n',), true)
    # check for unparsed junk after an expression
    t = peek_token(ps, ts)
    if !(Lexer.eof(t) || t === '\n')
        error("extra token \"$t\" after end of expression")
    end
    return ex
end

function parse_eq(ps::ParseState, ts::TokenStream) 
    lno = curline(ts)
    ex  = parse_RtoL(ps, ts, parse_comma, Lexer.precedent_ops(1))
    return short_form_function_loc(ex, lno)
end

# parse-eqs is used where commas are special for example in an argument list 
parse_eqs(ps::ParseState, ts::TokenStream)   = parse_RtoL(ps, ts, parse_cond, Lexer.precedent_ops(1))

# parse-comma is neeed for commas outside parens, for example a = b, c
parse_comma(ps::ParseState, ts::TokenStream) = parse_Nary(ps, ts, parse_cond, (',',), :tuple, (), false)

parse_or(ps::ParseState, ts::TokenStream)    = parse_LtoR(ps, ts, parse_and, Lexer.precedent_ops(3))
parse_and(ps::ParseState, ts::TokenStream)   = parse_LtoR(ps, ts, parse_arrow, Lexer.precedent_ops(4))
parse_arrow(ps::ParseState, ts::TokenStream) = parse_RtoL(ps, ts, parse_ineq, Lexer.precedent_ops(5))
parse_ineq(ps::ParseState, ts::TokenStream)  = parse_comparison(ps, ts, Lexer.precedent_ops(6))

const EXPR_OPS = Lexer.precedent_ops(9)
parse_expr(ps::ParseState, ts::TokenStream)  = parse_with_chains(ps, ts, parse_shift, EXPR_OPS, :(+))
parse_shift(ps::ParseState, ts::TokenStream) = parse_LtoR(ps, ts, parse_term, Lexer.precedent_ops(10))

const TERM_OPS = Lexer.precedent_ops(11)
parse_term(ps::ParseState, ts::TokenStream)     = parse_with_chains(ps, ts, parse_rational, TERM_OPS, :(*))

parse_rational(ps::ParseState, ts::TokenStream) = parse_LtoR(ps, ts, parse_unary, Lexer.precedent_ops(12))

parse_pipes(ps::ParseState, ts::TokenStream)    = parse_LtoR(ps, ts, parse_range, Lexer.precedent_ops(7))
parse_in(ps::ParseState, ts::TokenStream)       = parse_LtoR(ps, ts, parse_pipes, (:(in),))

function parse_comparison(ps::ParseState, ts::TokenStream, ops)
    ex = parse_in(ps, ts)
    isfirst = true
    while true 
        t = peek_token(ps, ts)
        !(t in ops) && return ex
        take_token(ts)
        if isfirst
            isfirst = false
            ex = Expr(:comparison, ex, t, parse_range(ps, ts))
        else
            push!(ex.args, t)
            push!(ex.args, parse_range(ps, ts))
        end
    end
end

is_large_number(n::BigInt) = true
is_large_number(n::Number) = false

const is_juxtaposed = let invalid_chars = Set{Char}(['(', '[', '{'])

    is_juxtaposed(ps::ParseState, ex, t::Token) = begin
        return !(Lexer.is_operator(t)) &&
               !(Lexer.is_operator(ex)) &&
               !(t in Lexer.reserved_words) &&
               !(is_closing_token(ps, t)) &&
               !(Lexer.isnewline(t)) &&
               !(isa(ex, Expr) && ex.head === :(...)) &&
               (isa(t, Number) || !(isa(t, Char) && t in invalid_chars))
    end
end

#= This handles forms such as 2x => Expr(:call, :*, 2, :x) =#
function parse_juxtaposed(ps::ParseState, ts::TokenStream, ex) 
    # numeric literal juxtaposition is a unary operator
    if is_juxtaposed(ps, ex, peek_token(ps, ts)) && !ts.isspace
        return Expr(:call, :(*), ex, parse_unary(ps, ts))
    end
    return ex
end

function parse_range(ps::ParseState, ts::TokenStream)
    ex = parse_expr(ps, ts)
    isfirst = true
    while true
        t = peek_token(ps, ts)
        if isfirst && t === :(..)
           take_token(ts)
           return Expr(:call, t, ex, parse_expr(ps, ts))
        end
        if ps.range_colon_enabled && t === :(:)
            take_token(ts)
            if ps.space_sensitive && ts.isspace
                peek_token(ps, ts)
                if !ts.isspace
                    # "a :b" in space sensitive mode
                    put_back!(ts, :(:))
                    return ex
                end
            end
            if is_closing_token(ps, peek_token(ps, ts))
                # handles :(>:) case
                if isa(ex, Symbol) && Lexer.is_operator(ex)
                    op = symbol(string(ex, t))
                    Lexer.is_operator(op) && return op
                end
                error("deprecated syntax arr[i:]")
            end
            if Lexer.isnewline(peek_token(ps, ts))
                error("line break in \":\" expression")
            end
            arg = parse_expr(ps, ts)
            if !ts.isspace && (arg === :(<) || arg === :(>))
                error("\":$argument\" found instead of \"$argument:\"")
            end
            if isfirst
                ex = Expr(t, ex, arg)
                isfirst = false
            else
                push!(ex.args, arg)
                isfirst = true
            end
            continue
        elseif t === :(...)
            take_token(ts)
            return Expr(:(...), ex)
        else
            return ex
        end
    end
end 

function parse_decl(ps::ParseState, ts::TokenStream)
    ex = parse_call(ps, ts)
    while true
        nt = peek_token(ps, ts)
        # type assertion => x::Int
        if nt === :(::)
            take_token(ts)
            ex = Expr(:(::), ex, parse_call(ps, ts))
            continue
        end
        # anonymous function => (x) -> x + 1
        if nt === :(->)
            take_token(ts)
            # -> is unusual it binds tightly on the left and loosely on the right
            lno = line_number_filename_node(ts)
            return Expr(:(->), ex, Expr(:block, lno, parse_eqs(ps, ts)))
        end
        return ex
    end
end

# handle ^ and .^
function parse_factorh(ps::ParseState, ts::TokenStream, down::Function, ops)
    ex = down(ps, ts)
    nt = peek_token(ps, ts)
    !(nt in ops) && return ex
    take_token(ts)
    pf = parse_factorh(ps, ts, parse_unary, ops)  
    return Expr(:call, nt, ex, pf)
end

negate(ex::Expr) = ex.head === :(-) && length(ex.args) == 1 ? ex.args[1] : Expr(:-, ex) 
negate(n::Int128) = n == -170141183460469231731687303715884105728 ? # promote to BigInt
                          170141183460469231731687303715884105728 : -n
negate(n::Int64)  = n == -9223372036854775808 ? # promote to Int128
                          9223372036854775808 : -n 
negate(n::BigInt)  = -n
negate(n::Float32) = -n
negate(n::Float64) = -n

# -2^3 is parsed as -(2^3) so call parse-decl for the first arg,
# and parse unary from then on (handles 2^-3)
parse_factor(ps::ParseState, ts::TokenStream) = parse_factorh(ps, ts, parse_decl, Lexer.precedent_ops(13))

function parse_unary(ps::ParseState, ts::TokenStream)
    t = require_token(ps, ts)
    is_closing_token(ps, t) && error("unexpected $t")
    if !(isa(t, Symbol) && t in Lexer.unary_ops)
        pf = parse_factor(ps, ts)
        return parse_juxtaposed(ps, ts, pf) 
    end
    op = take_token(ts)
    nc = Lexer.peekchar(ts.io)
    if (op === :(-) || op === :(+)) && (isdigit(nc) || nc === '.')
        neg = op === :(-)
        leadingdot = nc === '.'
        leadingdot && Lexer.readchar(ts.io)
        n   = Lexer.read_number(ts.io, leadingdot, neg)
        num = parse_juxtaposed(ps, ts, n)
        if peek_token(ps, ts) in (:(^), :(.^))
            # -2^x parsed as (- (^ 2 x))
            put_back!(ts, neg ? negate(num) : num)
            return Expr(:call, op, parse_factor(ps, ts))
        end 
        return num
    end
    nt = peek_token(ps, ts)
    if is_closing_token(ps, nt) || Lexer.isnewline(nt)
        # return operator by itself, as in (+)
        return op
    elseif nt === '{'
        # this case is +{T}(x::T)
        put_back!(ts, op)
        return parse_factor(ps, ts)
    else
        arg = parse_unary(ps, ts)
        if isa(arg, Expr) && arg.head === :tuple
            return Expr(:call, op, arg.args...)
        end 
        return Expr(:call, op, arg)
    end
end

function subtype_syntax(ex)
    if isa(ex, Expr) && ex.head === :comparison && length(ex.args) == 3 && ex.args[2] === :(<:)
        return Expr(:(<:), ex.args[1], ex.args[3])
    end
    return ex
end

function parse_unary_prefix(ps::ParseState, ts::TokenStream)
    op = peek_token(ps, ts)
    if isa(op, Symbol) && Lexer.is_syntactic_unary_op(op)
        take_token(ts)
        if is_closing_token(ps, peek_token(ps, ts))
            return op
        elseif op === :(&) || op === :(::)
            return Expr(op, parse_call(ps, ts))
        else
            return Expr(op, parse_atom(ps, ts))
        end
    end
    return parse_atom(ps, ts)
end

# parse function all, indexing, dot, and transpose expressions
# also handles looking for reserved words 
function parse_call(ps::ParseState, ts::TokenStream)
    ex = parse_unary_prefix(ps, ts)
    if isa(ex, Symbol) && ex in Lexer.reserved_words
        return parse_resword(ps, ts, ex)
    end
    return parse_call_chain(ps, ts, ex, false)
end

function separate(f::Function, collection)
    tcoll, fcoll = {}, {}
    for c in collection
        f(c) ? push!(tcoll, c) : push!(fcoll, c)
    end
    return (tcoll, fcoll)
end

function parse_call_chain(ps::ParseState, ts::TokenStream, ex, one_call::Bool)
    while true 
        t = peek_token(ps, ts)
        if (ps.space_sensitive && ts.isspace && (t in ('(', '[','{', '"', sym_squote)) ||
           (isa(ex, Number) && t === '('))
            return ex
        end
        if t === '('
            take_token(ts)
            arglist = parse_arglist(ps, ts, ')')
            isparam = (ex) -> isa(ex, Expr) && ex.head === :parameters && length(ex.args) == 1
            params, args = separate(isparam, arglist)
            if peek_token(ps, ts) === sym_do
                take_token(ts)
                ex = Expr(:call, ex, params..., parse_do(ps, ts), args...)
            else
                ex = Expr(:call, ex, arglist...)
            end
            one_call && return ex
            continue
        
        elseif t === '['
            take_token(ts)
            # ref is syntax so can distinguish a[i] = x from ref(a, i) = x
            al = with_end_symbol(ps) do 
                parse_cat(ps, ts, ']')
            end
            if (al.head === :cell1d || al.head === :vcat) && isempty(al.args)
                ex = is_dict_literal(ex) ? Expr(:typed_dict, ex) : Expr(:ref, ex)
                continue
            end
            if al.head === :dict
                ex = Expr(:typed_dict, ex, al.args...)
            elseif al.head === :hcat
                ex = Expr(:typed_hcat, ex, al.args...)
            elseif al.head === :vcat
                istyped = (ex) -> isa(ex, Expr) && ex.head === :row
                ex = any(istyped, al.args) ? Expr(:typed_vcat, ex, al.args...) :
                                             Expr(:ref, ex, al.args...)
            elseif al.head === :comprehension
                ex = Expr(:typed_comprehension, ex, al.args...)
            elseif al.head === :dict_comprehension
                ex = Expr(:typed_dict_comprehension, ex, al.args...)
            else
                error("unknown parse-cat result (internal error)")
            end
            continue

        elseif t === :(.)
            take_token(ts)
            nt = peek_token(ps, ts)
            if nt === '('
                ex = Expr(:(.), ex, parse_atom(ps, ts))
            elseif nt === :($)
                dollar_ex = parse_unary(ps, ts)
                call_ex   = Expr(:call, TopNode(:Expr), Expr(:quote, :quote), dollar_ex.args[1])
                ex = Expr(:(.), ex, Expr(:($), call_ex))
            else
                name = parse_atom(ps, ts)
                if isa(name, Expr) && name.head === :macrocall
                    ex = Expr(:macrocall, Expr(:(.), ex, Expr(:quote, name.args[1])))
                    append!(ex.args, name.args[2:end])
                else
                    ex = Expr(:(.), ex, Expr(:quote, name))
                end
            end
            continue

        elseif t === :(.') || t === sym_squote
            take_token(ts)
            ex = Expr(t, ex)
            continue

        elseif t === '{'
            take_token(ts)
            args = map(subtype_syntax, parse_arglist(ps, ts, '}'))
            # ::Type{T}
            if isa(ex, Expr) && ex.head == :(::)
                ex = Expr(:(::), Expr(:curly, first(ex.args), args...))
            else
                ex = Expr(:curly, ex, args...)
            end
            continue

        elseif t === '"'
            if isa(ex, Symbol) && !Lexer.is_operator(ex) && !ts.isspace
                # custom prefexed string literals x"s" => @x_str "s"
                take_token(ts)
                str = parse_string_literal(ps, ts, true)
                nt  = peek_token(ps, ts)
                suffix  = triplequote_string_literal(str) ? "_mstr" : "_str"
                macname = symbol(string('@', ex, suffix))
                macstr  = str.args[1]
                if isa(nt, Symbol) && !Lexer.is_operator(nt) && !ts.isspace
                    # string literal suffix "s"x
                    ex = Expr(:macrocall, macname, macstr, string(take_token(ts)))
                else
                    ex = Expr(:macrocall, macname, macstr)
                end
                continue
            end
            return ex
        end
        return ex
    end
end 

const expect_end_current_line = 0

function expect_end(ps::ParseState, ts::TokenStream, word::Symbol)
    t = peek_token(ps, ts)
    if t === sym_end
        take_token(ts)
    elseif Lexer.eof(t)
        err_msg = "incomplete: \"$word\" at {current_filename} : {expected} requires end"
        error(err_msg)
    else
        err_msg = "incomplete: \"$word\" at {current filename} : {expected} \"end\", got \"$t\""
        error(err_msg)
    end
end

parse_subtype_spec(ps::ParseState, ts::TokenStream) = subtype_syntax(parse_ineq(ps, ts))

# parse expressions or blocks introduced by syntatic reserved words
function parse_resword(ps::ParseState, ts::TokenStream, word::Symbol)
    expect_end_current_line = curline(ts)
    with_normal_ops(ps) do
        without_whitespace_newline(ps) do
            if word === :quote || word === :begin
                Lexer.skipws_and_comments(ts.io)
                loc = line_number_filename_node(ts)
                blk = parse_block(ps, ts)
                expect_end(ps, ts, word)
                
                local ex::Expr
                if !isempty(blk.args) && isa(blk.args[1], Expr) && blk.args[1].head === :line
                    ex = Expr(:block, loc)
                    append!(ex.args, blk.args[2:end])
                else
                    ex = blk
                end
                return word === :quote ? Expr(:quote, ex) : ex

            elseif word === :while
                ex = Expr(:while, parse_cond(ps, ts), parse_block(ps, ts))
                expect_end(ps, ts, word)
                return ex

            elseif word === :for
                ranges  = parse_comma_sep_iters(ps, ts)
                nranges = length(ranges) 
                body = parse_block(ps, ts)
                expect_end(ps, ts, word)
                if nranges == 1
                    return Expr(:for, ranges[1], body)
                else
                    # handles forms such as for i=1:10,j=1:10...
                    ex = lastex = Expr(:for, ranges[1])
                    for i=2:nranges
                        push!(lastex.args, Expr(:for, ranges[i]))
                        lastex = lastex.args[end]
                        if i == nranges
                            push!(lastex.args, body)
                        end
                    end
                    return ex
                end

            elseif word === :if
                test = parse_cond(ps, ts)
                t    = require_token(ps, ts)
                then = t === sym_else || t === sym_elseif ? Expr(:block) : parse_block(ps, ts)
                nxt = require_token(ps, ts)
                take_token(ts)
                if nxt === sym_end
                    return Expr(:if, test, then)
                elseif nxt === sym_elseif
                    if Lexer.isnewline(peek_token(ps, ts))
                        error("missing condition in elseif at {filename} : {line}")
                    end
                    blk = Expr(:block, line_number_node(ts), parse_resword(ps, ts, :if))
                    return Expr(:if, test, then, blk)
                elseif nxt === sym_else
                    if peek_token(ps, ts) === :if
                        error("use elseif instead of else if")
                    end
                    blk = parse_block(ps, ts)
                    ex = Expr(:if, test, then, blk) 
                    expect_end(ps, ts, word)
                    return ex
                else
                    error("unexpected next token $nxt in if")
                end

            elseif word === :let
                nt = peek_token(ps, ts)
                binds = Lexer.isnewline(nt) || nt === ';' ? {} : parse_comma_sep_assigns(ps, ts)
                nt = peek_token(ps, ts)
                if !(Lexer.eof(nt) || (isa(nt, CharSymbol) && nt in ('\n', ';', sym_end)))
                    error("let variables should end in \";\" or newline")
                end
                ex = parse_block(ps, ts)
                expect_end(ps, ts, word)
                return Expr(:let, ex, binds...)

            elseif word === :global || word === :local
                lno = curline(ts)
                isconst = peek_token(ps, ts) === :const ? (take_token(ts); true) : false
                args = map((ex) -> short_form_function_loc(ex, lno), 
                           parse_comma_sep_assigns(ps, ts))
                return isconst ? Expr(:const, Expr(word, args...)) :
                                 Expr(word, args...)

            elseif word === :function || word === :macro
                paren = require_token(ps, ts) === '('
                sig   = parse_call(ps, ts)
                local def::Expr
                if isa(sig, Symbol) || (isa(sig, Expr) && sig.head === :(::) && 
                                        isa(sig.args[1], Symbol))
                   if paren
                       # in function(x) the (x) is a tuple
                       def = Expr(:tuple, sig)
                    else
                       # function foo => syntax error
                       error("expected \"(\" in $word definition")
                    end
                else
                    if (isa(sig, Expr) && (sig.head === :call || sig.head === :tuple))
                        def = sig
                    else
                        error("expected \"(\" in $word definition")
                    end
                end
                peek_token(ps, ts) !== sym_end && Lexer.skipws_and_comments(ts.io)
                loc  = line_number_filename_node(ts)
                body = parse_block(ps, ts)
                expect_end(ps, ts, word)
                add_filename_to_block!(body, loc)
                return Expr(word, def, body)

            elseif word === :abstract
                return Expr(:abstract, parse_subtype_spec(ps, ts))

            elseif word === :type || word === :immutable
                istype = word === :type
                # allow "immutable type"
                (!istype && peek_token(ps, ts) === :type) && take_token(ts)
                sig = parse_subtype_spec(ps, ts)
                blk = parse_block(ps, ts)
                ex  = Expr(:type, istype, sig, blk) 
                expect_end(ps, ts, word)
                return ex

            elseif word === :bitstype
                stmnt = with_space_sensitive(ps) do
                    parse_cond(ps, ts)
                end
                return Expr(:bitstype, stmnt, parse_subtype_spec(ps, ts))

            elseif word === :typealias
                lhs = parse_call(ps, ts)
                if isa(lhs, Expr) && lhs.head === :call 
                    # typealias X (...) is a tuple type alias, not call
                    return Expr(:typealias, lhs.args[1], Expr(:tuple, lhs.args[2:end]...))
                else
                    return Expr(:typealias, lhs, parse_arrow(ps, ts))
                end

            elseif word === :try
                t = require_token(ps, ts)
                tryb = t === sym_catch || t === sym_finally ? Expr(:block) : parse_block(ps, ts)
                t = require_token(ps, ts)
                catchb = nothing
                catchv = false
                finalb = nothing
                while true
                    take_token(ts)
                    if t === sym_end 
                        if finalb != nothing
                            return catchb != nothing ? Expr(:try, tryb, catchv, catchb, finalb) :
                                                       Expr(:try, tryb, catchv, false, finalb)
                        else
                            return catchb != nothing ? Expr(:try, tryb, catchv, catchb) :
                                                       Expr(:try, tryb, catchv, false)
                        end
                    end
                    if t === sym_catch && catchb == nothing
                        nl  = Lexer.isnewline(peek_token(ps, ts))
                        t   = require_token(ps, ts)
                        if t === sym_end || t === sym_finally
                            catchb = Expr(:block)
                            catchv = false 
                            continue
                        else
                            var   = parse_eqs(ps, ts)
                            isvar = nl == false && isa(var, Symbol)
                            catch_block = require_token(ps, ts) === sym_finally ? Expr(:block) : parse_block(ps, ts)
                            t = require_token(ps, ts)
                            catchb = isvar ? catch_block : Expr(:block, var, catch_block.args...)
                            catchv = isvar ? var : false
                            continue
                        end
                    elseif t === sym_finally && finalb == nothing
                        finalb = require_token(ps, ts) === sym_catch ? Expr(:block) : parse_block(ps, ts)
                        t = require_token(ps, ts)
                        continue 
                    else
                        error("unexpected \"$t\"")
                    end
                end

            elseif word === :return
                t  = peek_token(ps, ts)
                return Lexer.isnewline(t) || is_closing_token(ps, t) ? Expr(:return, nothing) :
                                                                       Expr(:return, parse_eq(ps, ts))
            elseif word === :break || word === :continue
                return Expr(word)

            elseif word === :const
                assgn = parse_eq(ps, ts)
                if !(isa(assgn, Expr) && (assgn.head === :(=) || 
                                          assgn.head === :global || 
                                          assgn.head === :local))
                    error("expected assignment after \"const\"")
                end
                return Expr(:const, assgn)

            elseif word === :module || word === :baremodule
                isbare = word === :baremodule
                name = parse_atom(ps, ts)
                body = parse_block(ps, ts)
                expect_end(ps, ts, word)
                if !isbare
                    # add definitions for module_local eval
                    block = Expr(:block)
                    x = name === :x ? :y : :x
                    push!(block.args, 
                        Expr(:(=), Expr(:call, :eval, x),
                                   Expr(:call, Expr(:(.), TopNode(:Core), 
                                               Expr(:quote, :eval)), name, x)))
                    push!(block.args,
                        Expr(:(=), Expr(:call, :eval, :m, :x),
                                   Expr(:call, Expr(:(.), TopNode(:Core),
                                               Expr(:quote, :eval)), :m, :x)))
                    append!(block.args, body.args)
                    body = block
                end
                return Expr(:module, !isbare, name, body) 

            elseif word === :export
                exports = map(macrocall_to_atsym, parse_comma_sep(ps, ts, parse_atom))
                !all(x -> isa(x, Symbol), exports) && error("invalid \"export\" statement")
                ex = Expr(:export); ex.args = exports
                return ex

            elseif word === :import || word === :using || word === :importall
                imports = parse_imports(ps, ts, word)
                return length(imports) == 1 ? imports[1] : Expr(:toplevel, imports...)

            elseif word === :ccall
                peek_token(ps, ts) != '(' && error("invalid \"ccall\" syntax")
                take_token(ts)
                al = parse_arglist(ps, ts, ')')
                if length(al) > 1 && al[2] in (:cdecl, :stdcall, :fastcall, :thiscall)
                    # place calling convention at end of arglist
                    return Expr(:ccall, al[1], al[3:end]..., Expr(al[2]))
                end
                ex = Expr(:ccall); ex.args = al
                return ex

            elseif word === :do
                error("invalid \"do\" syntax")

            else
                error("unhandled reserved word $word")
            end 
        end
    end
end

function add_filename_to_block!(body::Expr, loc)
    if !isempty(body.args) && isa(body.args[1], Expr) && body.args[1].head === :line
        body.args[1] = loc
    end
    return body
end

function parse_do(ps::ParseState, ts::TokenStream)
    #TODO: line endings
    expect_end_current_line = curline(ts)
    without_whitespace_newline(ps) do
        doargs = Lexer.isnewline(peek_token(ps, ts)) ? {} : parse_comma_sep(ps, ts, parse_range)
        loc = line_number_filename_node(ts)
        blk = parse_block(ps, ts)
        add_filename_to_block!(blk, loc)
        expect_end(ps, ts, :do)
        return Expr(:(->), Expr(:tuple, doargs...), blk)
    end
end

macrocall_to_atsym(ex) = isa(ex, Expr) && ex.head === :macrocall ? ex.args[1] : ex

function parse_imports(ps::ParseState, ts::TokenStream, word::Symbol)
    frst = {parse_import(ps, ts, word)}
    nt   = peek_token(ps, ts)
    from = nt === :(:) && !ts.isspace 
    done = false
    if from || nt === ','
        take_token(ts)
        done = false
    elseif nt in ('\n', ';')
        done = true
    elseif Lexer.eof(nt)
        done = true
    else
        done = false
    end
    rest = done? {} : parse_comma_sep(ps, ts, (ps, ts) -> parse_import(ps, ts, word))
    if from
        module_syms = frst[1].args
        imports = Expr[]
        for expr in rest
            ex = Expr(expr.head, module_syms..., expr.args...)
            push!(imports, ex)
        end
        return imports
    end
    return append!(frst, rest)
end

const sym_1dot  = symbol(".")
const sym_2dots = symbol("..")
const sym_3dots = symbol("...")
const sym_4dots = symbol("....")

function parse_import_dots(ps::ParseState, ts::TokenStream)
    l = {}
    t = peek_token(ps, ts)
    while true
        if t === sym_1dot
            take_token(ts)
            push!(l, :(.))
            t = peek_token(ps, ts)
            continue
        elseif t === sym_2dots
            take_token(ts)
            append!(l, {:(.), :(.)})
            t = peek_token(ps, ts)
            continue
        elseif t === sym_3dots
            take_token(ts)
            append!(l, {:(.), :(.), :(.)})
            t = peek_token(ps, ts)
            continue
        elseif t === sym_4dots
            take_token(ts)
            append!(l, {:(.), :(.), :(.), :(.)})
            t = peek_token(ps, ts)
            continue
        end
        return push!(l, macrocall_to_atsym(parse_atom(ps, ts)))
    end
end

function parse_import(ps::ParseState, ts::TokenStream, word::Symbol)
    path = parse_import_dots(ps, ts)
    while true
        # this handles cases such as Base.* where .* is a valid operator token
        nc = Lexer.peekchar(ts.io)
        if nc === '.'
            Lexer.takechar(ts.io)
            push!(path, macrocall_to_atsym(parse_atom(ps, ts)))
            continue
        end
        nt = peek_token(ps, ts)
        if Lexer.eof(nt) || (isa(nt, CharSymbol) && nt in ('\n', ';', ',', :(:)))
            ex = Expr(word); ex.args = path
            return ex
        else
            error("invalid \"$word\" statement")
        end
    end
end

function parse_comma_sep(ps::ParseState, ts::TokenStream, what::Function)
    exprs = {}
    while true 
        r = what(ps, ts)
        if peek_token(ps, ts) === ','
            take_token(ts)
            push!(exprs, r)
            continue
        end 
        push!(exprs, r)
        return exprs
    end
end

parse_comma_sep_assigns(ps::ParseState, ts::TokenStream) = parse_comma_sep(ps, ts, parse_eqs) 

# as above, but allows both "i=r" and "i in r"
# return a list of range expressions
function parse_comma_sep_iters(ps::ParseState, ts::TokenStream)
    ranges = {}
    while true 
        r = parse_eqs(ps, ts)
        if r === :(:)
        elseif isa(r, Expr) && r.head === :(=)
        elseif isa(r, Expr) && r.head === :in
            r = Expr(:(=), r.args...)
        else
            error("invalid iteration spec")
        end
        if peek_token(ps, ts) === ','
            take_token(ts)
            push!(ranges, r)
            continue
        end
        push!(ranges, r)
        return ranges
    end
end
       
function parse_space_separated_exprs(ps::ParseState, ts::TokenStream)
    with_space_sensitive(ps) do
        exprs = {}
        while true 
            nt = peek_token(ps, ts)
            if is_closing_token(ps, nt) ||
               Lexer.isnewline(nt) || 
               (ps.inside_vector && nt === :for)
                return exprs
            end
            ex = parse_eq(ps, ts)
            if Lexer.isnewline(peek_token(ps, ts))
                push!(exprs, ex)
                return exprs
            end
            push!(exprs, ex)
        end
    end
end

is_assignment(ex::Expr) = ex.head === :(=) && length(ex.args) == 2
is_assignment(ex) = false

to_kws(lst) = map((ex) -> is_assignment(ex) ? Expr(:kw, ex.args...) : ex, lst)

# handle function call argument list, or any comma-delimited list
# * an extra comma at the end is allowed
# * expressions after a ; are enclosed in (parameters ....)
# * an expression followed by ... becomes (.... x)
function _parse_arglist(ps::ParseState, ts::TokenStream, closer::Token)
    lst = {} 
    while true 
        t = require_token(ps, ts)
        if t === closer
            take_token(ts)
            # x=y inside a function call is a keyword argument
            return closer === ')' ? to_kws(lst) : lst
        elseif t === ';'
            take_token(ts)
            # allow f(a, b; )
            peek_token(ps, ts) === closer && continue
            params = parse_arglist(ps, ts, closer)
            lst = closer === ')' ? to_kws(lst) : lst
            return unshift!(lst, Expr(:parameters, params...))
        end
        nxt = parse_eqs(ps, ts)
        nt  = require_token(ps, ts)
        if nt === ','
            take_token(ts)
            push!(lst, nxt)
            continue
        elseif nt === ';'
            push!(lst, nxt)
            continue
        elseif nt === closer
            push!(lst, nxt)
            continue
        elseif nt in (']', '}')
            error("unexpected \"$nt\" in argument list")
        else
            error("missing comma or \"$closer\" in argument list")
        end
    end
end

function parse_arglist(ps::ParseState, ts::TokenStream, closer::Token)
    with_normal_ops(ps) do
        with_whitespace_newline(ps) do
            return _parse_arglist(ps, ts, closer)
        end
    end
end

# parse [] concatenation exprs and {} cell exprs
function parse_vcat(ps::ParseState, ts::TokenStream, frst, closer)
    lst = {}
    nxt = frst
    while true 
        t = require_token(ps, ts)
        if t === closer
            take_token(ts)
            ex = Expr(:vcat); ex.args = push!(lst, nxt)
            return ex
        end
        if t === ','
            take_token(ts)
            if require_token(ps, ts) === closer
                # allow ending with ,
                take_token(ts)
                ex = Expr(:vcat); ex.args = push!(lst, nxt)
                return ex
            end
            lst = push!(lst, nxt) 
            nxt = parse_eqs(ps, ts)
            continue
        elseif t === ';'
            error("unexpected semicolon in array expression")
        elseif t === ']' || t === '}'
            error("unexpected \"$t\" in array expression")
        else
            error("missing separator in array expression")
        end
    end
end


function parse_dict(ps::ParseState, ts::TokenStream, frst, closer)
    v = parse_vcat(ps, ts, frst, closer)
    local alldl::Bool
    for arg in v.args
        alldl = is_dict_literal(arg)
        alldl || break
    end
    if alldl
        ex = Expr(:dict); ex.args = v.args 
        return ex
    else
        error("invalid dict literal")
    end
end

function parse_comprehension(ps::ParseState, ts::TokenStream, frst, closer)
    itrs = parse_comma_sep_iters(ps, ts)
    t = require_token(ps, ts)
    t === closer ? take_token(ts) : error("expected $closer")
    return Expr(:comprehension, frst, itrs...)
end

function parse_dict_comprehension(ps::ParseState, ts::TokenStream, frst, closer)
    c = parse_comprehension(ps, ts, frst, closer)
    if is_dict_literal(c.args[1])
        ex = Expr(:dict_comprehension); ex.args = c.args
        return ex
    else
        error("invalid dict comprehension")
    end
end


function parse_matrix(ps::ParseState, ts::TokenStream, frst, closer)

    update_outer!(v, outer) = begin
        len = length(v)
        len == 0 && return outer
        len == 1 && return push!(outer, v[1])
        row = Expr(:row); row.args = v
        return push!(outer, row) 
    end

    semicolon = peek_token(ps, ts) === ';'
    vec   = {frst}
    outer = {}
    while true 
        t::Token = peek_token(ps, ts) === '\n' ? '\n' : require_token(ps, ts)
        if t === closer
            take_token(ts)
            local ex::Expr
            if !isempty(outer)
                ex = Expr(:vcat); ex.args = update_outer!(vec, outer)
            elseif length(vec) <= 1
                # [x] => (vcat x)
                ex = Expr(:vcat); ex.args = vec
            else
                # [x y] => (hcat x y)
                ex = Expr(:hcat); ex.args = vec
            end
            return ex
        end
        if t === ';' || t === '\n'
            take_token(ts)
            outer = update_outer!(vec, outer)
            vec   = {}
            continue
        elseif t === ','
            error("unexpected comma in matrix expression")
        elseif t === ']' || t === '}'
            error("unexpected \"$t\"")
        elseif t === :for
            if !semicolon && length(outer) == 1 && isempty(vec)
                take_token(ts)
                return parse_comprehension(ps, ts, outer[1], closer)
            else
                error("invalid comprehension syntax")
            end
        else
            push!(vec, parse_eqs(ps, ts))
            continue
        end
    end
end

function peek_non_newline_token(ps::ParseState, ts::TokenStream)
    while true
        t = peek_token(ps, ts)
        if Lexer.isnewline(t)
            take_token(ts)
            continue
        end
        return t
    end
end

function parse_cat(ps::ParseState, ts::TokenStream, closer)
    with_normal_ops(ps) do
        with_inside_vec(ps) do
            if require_token(ps, ts) === closer
                take_token(ts)
                if closer === '}'
                    return Expr(:cell1d)
                elseif closer === ']'
                    return Expr(:vcat)
                else
                    error("unknown closer $closer")
                end
            end
            frst = parse_eqs(ps, ts)
            if is_dict_literal(frst)
                nt = peek_non_newline_token(ps, ts)
                if nt === :for 
                    take_token(ts)
                    return parse_dict_comprehension(ps, ts, frst, closer)
                else
                    return parse_dict(ps, ts, frst, closer)
                end
            end
            nt = peek_token(ps, ts)
            if nt === ','
                return parse_vcat(ps, ts, frst, closer)
            elseif nt === :for
                take_token(ts)
                return parse_comprehension(ps, ts, frst, closer)
            else
                return parse_matrix(ps, ts, frst, closer)
            end
        end
    end
end

function parse_tuple(ps::ParseState, ts::TokenStream, frst)
    args = {}
    nxt = frst
    while true
        t = require_token(ps, ts)
        if t === ')'
            take_token(ts)
            ex = Expr(:tuple); ex.args = push!(args, nxt)
            return ex
        end
        if t === ','
            take_token(ts)
            if require_token(ps, ts) === ')'
                # allow ending with ,
                take_token(ts)
                ex = Expr(:tuple); ex.args = push!(args, nxt)
                return ex
            end
            args = push!(args, nxt) 
            nxt  = parse_eqs(ps, ts)
            continue
        elseif t === ';'
            error("unexpected semicolon in tuple")
        elseif t === ']' || t === '}'
            error("unexpected \"$(peek_token(ps, ts))\" in tuple")
        else
            error("missing separator in tuple")
        end
    end
end

# TODO: these are unnecessary if base/client.jl didn't need to parse error string
function not_eof_1(c)
    Lexer.eof(c) && error("incomplete: invalid character literal")
    return c
end

function not_eof_2(c)
    Lexer.eof(c) && error("incomplete: invalid \"`\" syntax")
    return c
end

function not_eof_3(c)
    Lexer.eof(c) && error("incomplete: invalid string syntax")
    return c
end 

#TODO; clean up eof handling
function parse_backquote(ps::ParseState, ts::TokenStream)
    buf = IOBuffer()
    c   = Lexer.readchar(ts.io)
    while true 
        c === '`' && break
        if c === '\\'
            nc = Lexer.readchar(ts.io)
            if nc === '`'
                write(buf, nc)
            else
                write(buf, '\\')
                write(buf, not_eof_2(nc))
            end
        else
            write(buf, not_eof_2(c))
        end
        c = Lexer.readchar(ts.io)
        continue
    end
    return Expr(:macrocall, symbol("@cmd"), bytestring(buf))
end

function parse_interpolate(ps::ParseState, ts::TokenStream)
    c = Lexer.peekchar(ts.io)
    if Lexer.is_identifier_char(c)
        return parse_atom(ps, ts)
    elseif c === '('
        Lexer.readchar(ts.io)
        ex = parse_eqs(ps, ts)
        require_token(ps, ts) === ')' || error("invalid interpolation syntax")
        take_token(ts)
        return ex
    else
        error("invalid interpolation syntax: \"$c\"")
    end
end

function tostr(buf::IOBuffer, custom::Bool)
    str = bytestring(buf)
    custom && return str
    str = unescape_string(str)
    !is_valid_utf8(str) && error("invalid UTF-8 sequence")
    return str
end

function _parse_string_literal(ps::ParseState, ts::TokenStream, head::Symbol, n::Integer, custom::Bool)
    c  = Lexer.readchar(ts.io)
    b  = IOBuffer()
    ex = Expr(head)
    quotes = 0
    while true 
        if c == '"'
            if quotes < n
                c = Lexer.readchar(ts.io)
                quotes += 1
                continue
            end
            push!(ex.args, tostr(b, custom))
            return ex
        elseif quotes == 1
            custom || write(b, '\\')
            write(b, '"')
            quotes = 0
            continue
        elseif quotes == 2
            custom || write(b, '\\')
            write(b, '"')
            custom || write(b, '\\')
            write(b, '"')
            quotes = 0
            continue
        elseif c === '\\'
            nxch = not_eof_3(Lexer.readchar(ts.io))
            if !custom || nxch !== '"' 
                write(b, '\\')
            end
            write(b, nxch)
            c = Lexer.readchar(ts.io)
            quotes = 0
            continue
        elseif c === '$' && !custom
            iex = parse_interpolate(ps, ts)
            append!(ex.args, {tostr(b, custom), iex})
            c = Lexer.readchar(ts.io)
            b = IOBuffer()
            quotes = 0
            continue
        else
            write(b, not_eof_3(c))
            c = Lexer.readchar(ts.io)
            quotes = 0
            continue
        end
    end
end

interpolate_string_literal(ex) = isa(ex, Expr) && length(ex.args) > 1
triplequote_string_literal(ex) = isa(ex, Expr) && ex.head === :triple_quoted_string

function parse_string_literal(ps::ParseState, ts::TokenStream, custom)
    if Lexer.peekchar(ts.io)  === '"'
        Lexer.takechar(ts.io)
        if Lexer.peekchar(ts.io) === '"'
            Lexer.takechar(ts.io)
            return _parse_string_literal(ps, ts, :triple_quoted_string, 2, custom)
        end
        return Expr(:single_quoted_string, "")
    end
    return _parse_string_literal(ps, ts, :single_quoted_string, 0, custom)
end

function _parse_atom(ps::ParseState, ts::TokenStream)
    t = require_token(ps, ts)
    #Note: typeof(t) == Char, isa(t, Number) == true
    if !isa(t, Char) && isa(t, Number)
        return take_token(ts)
    
    # char literal
    elseif t === symbol("'")
        take_token(ts)
        fch = Lexer.readchar(ts.io)
        fch === '\'' && error("invalid character literal")
        if fch !== '\\' && !Lexer.eof(fch) && Lexer.peekchar(ts.io) === '\''
            # easy case 1 char no \
            Lexer.takechar(ts.io)
            return fch
        else
            c, b = fch, IOBuffer()
            while true
                c === '\'' && break
                write(b, not_eof_1(c))
                c === '\\' && write(b, not_eof_1(Lexer.readchar(ts.io)))
                c = Lexer.readchar(ts.io)
                continue
            end
            str = unescape_string(bytestring(b))
            #TODO: this does not make any sense and is broken 
            if length(str) == 1
                # one byte e.g. '\xff' maybe not valid UTF-8
                # but we want to use the raw value as a codepoint in this case
                # wchar str[0] 
                return str[1] 
            else
                if length(str) != 1  || !is_valid_utf8(str)
                    error("invalid character literal, got \'$str\'")
                end
                return str[1]
            end
        end
    
    # symbol / expression quote
    elseif t === :(:)
        take_token(ts)
        if is_closing_token(ps, peek_token(ps, ts))
            return :(:)
        end
        return Expr(:quote, _parse_atom(ps, ts)) 
    
    # misplaced =
    elseif t === :(=)
        error("unexpected \"=\"")

    # identifier
    elseif isa(t, Symbol)
        return take_token(ts)

    # parens or tuple
    elseif t === '('
        take_token(ts)
        with_normal_ops(ps) do
            with_whitespace_newline(ps) do
                if require_token(ps, ts) === ')'
                    # empty tuple
                    take_token(ts)
                    return Expr(:tuple)
                elseif peek_token(ps, ts) in Lexer.syntactic_ops
                    # allow (=) etc.
                    t = take_token(ts)
                    require_token(ps, ts) !== ')' && error("invalid identifier name \"$t\"")
                    take_token(ts)
                    return t
                else
                    # here we parse the first subexpression separately,
                    # so we can look for a comma to see if it is a tuple
                    # this lets us distinguish (x) from (x,)
                    ex = parse_eqs(ps, ts)
                    t  = require_token(ps, ts)
                    if t === ')'
                        take_token(ts)
                        if isa(ex, Expr) && ex.head === :(...)
                            # (ex...)
                            return Expr(:tuple, ex)
                        else
                            # value in parens (x)
                            return ex
                        end
                    elseif t === ','
                        # tuple (x,) (x,y) (x...) etc
                        return parse_tuple(ps, ts, ex)
                    elseif t === ';'
                        #parenthesized block (a;b;c)
                        take_token(ts)
                        if require_token(ps, ts) === ')'
                            # (ex;)
                            take_token(ts)
                            return Expr(:block, ex)
                        else
                            blk = parse_stmts_within_expr(ps, ts)
                            tok = require_token(ps, ts)
                            if tok === ','
                                error("unexpected comma in statment block")
                            elseif tok != ')'
                                error("missing separator in statement block")
                            end
                            take_token(ts)
                            return Expr(:block, ex, blk)
                        end
                    elseif t === ']' || t === '}'
                        error("unexpected \"$t\" in tuple")
                    else
                        error("missing separator in tuple")
                    end
                end
            end
        end
   
    # cell expression
    elseif t === '{'
        take_token(ts)
        if require_token(ps, ts) === '}'
            take_token(ts)
            return Expr(:cell1d)
        end
        vex = parse_cat(ps, ts, '}')
        if isempty(vex.args)
            return Expr(:cell1d)
        elseif vex.head === :comprehension
            ex = Expr(:typed_comprehension, TopNode(:Any))
            append!(ex.args, vex.args)
            return ex
        elseif vex.head === :dict_comprehension
            ex = Expr(:typed_dict_comprehension, Expr(:(=>), TopNode(:Any), TopNode(:Any)))
            append!(ex.args, vex.args)
            return ex
        elseif vex.head === :dict
            ex = Expr(:typed_dict, Expr(:(=>), TopNode(:Any), TopNode(:Any)))
            append!(ex.args, vex.args)
            return ex
        elseif vex.head === :hcat
            ex = Expr(:cell2d, 1, length(vex.args))
            append!(ex.args, vex.args)
            return ex
        else # Expr(:vcat, ...)
            nr = length(vex.args)
            if isa(vex.args[1], Expr) && vex.args[1].head === :row
                nc = length(vex.args[1].args)
                ex = Expr(:cell2d, nr, nc) 
                for i = 2:nr
                    row = vex.args[i]
                    if !(isa(row, Expr) && row.head === :row && length(row.args) == nc)
                        error("inconsistent shape in cell expression")
                    end
                end
                # Transpose to storage order
                sizehint(ex.args, nr * nc + 2)
                for c = 1:nc, r = 1:nr
                    push!(ex.args, vex.args[r].args[c])
                end
                return ex
            else
                for i = 2:nr
                    row = vex.args[i]
                    if isa(row, Expr) && row.head === :row
                        error("inconsistent shape in cell expression")
                    end
                end
                ex = Expr(:cell1d); ex.args = vex.args
                return ex
            end
        end

    # cat expression
    elseif t === '['
        take_token(ts)
        vex = parse_cat(ps, ts, ']')
        return vex

    # string literal
    elseif t === '"'
        take_token(ts)
        sl = parse_string_literal(ps, ts, false)
        if triplequote_string_literal(sl)
            return Expr(:macrocall, symbol("@mstr"), sl.args...)
        elseif interpolate_string_literal(sl) 
            notzerolen = (s) -> !(isa(s, String) && isempty(s))
            return Expr(:string, filter(notzerolen, sl.args)...)
        end
        return sl.args[1]

    # macro call
    elseif t === '@'
        take_token(ts)
        with_space_sensitive(ps) do
            head = parse_unary_prefix(ps, ts)
            if (peek_token(ps, ts); ts.isspace)
                ex = Expr(:macrocall, macroify_name(head))
                append!(ex.args, parse_space_separated_exprs(ps, ts))
                return ex
            else
                call = parse_call_chain(ps, ts, head, true)
                if isa(call, Expr) && call.head === :call
                    ex = Expr(:macrocall, macroify_name(call.args[1]))
                    append!(ex.args, call.args[2:end])
                    return ex
                else
                    ex = Expr(:macrocall, macroify_name(call))
                    append!(ex.args, parse_space_separated_exprs(ps, ts))
                    return ex
                end
            end
        end
    
    # command syntax
    elseif t === '`'
        take_token(ts)
        return parse_backquote(ps, ts)

    else
        error("invalid syntax: \"$(take_token(ts))\"")
    end
end

function parse_atom(ps::ParseState, ts::TokenStream)
    ex = _parse_atom(ps, ts)
    if (ex in Lexer.syntactic_ops) || ex === :(...)
        error("invalid identifier name \"$ex\"")
    end
    return ex
end

function is_valid_modref(ex::Expr)
    return length(ex.args) == 2 &&
           ex.head === :(.) &&
           ((isa(ex.args[2], Expr) && 
             ex.args[2].head === :quote && 
             isa(ex.args[2].args[1], Symbol)) ||
            (isa(ex.args[2], QuoteNode) &&
             isa(ex.args[2].value, Symbol))) &&
           (isa(ex.args[1], Symbol) || is_valid_modref(ex.args[1]))
end

function macroify_name(ex)
    if isa(ex, Symbol)
        return symbol(string('@', ex))
    elseif is_valid_modref(ex)
        return Expr(:(.), ex.args[1], Expr(:quote, macroify_name(ex.args[2].args[1])))
    else
        error("invalid macro use \"@($ex)")
    end
end

#========================#
# Parser Entry Method
#========================#

function parse(ts::TokenStream)
    Lexer.skipws_and_comments(ts.io)
    t::Token = Lexer.next_token(ts, false)
    while true
        Lexer.eof(t) && return nothing
        if Lexer.isnewline(t)
            t = Lexer.next_token(ts, false)
            continue
        end
        break
    end
    put_back!(ts, t)
    ps = ParseState()
    return parse_stmts(ps, ts)
end

parse(io::IO) = parse(TokenStream(io))
parse(str::String)  = parse(TokenStream(IOBuffer(str)))

end
