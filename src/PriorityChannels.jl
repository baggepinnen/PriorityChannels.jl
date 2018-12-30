module PriorityChannels


struct PriorityElement{T,I<:Integer}
    elem::T
    priority::I
end


"""
    PriorityChannel{T}(sz::Int)

Constructs a `Channel` with an internal buffer that can hold a maximum of `sz` objects
of type `T`.
[`put!`](@ref) calls on a full channel block until an object is removed with [`take!`](@ref).

`PriorityChannel(0)` constructs an unbuffered channel. `put!` blocks until a matching `take!` is called.
And vice-versa.

Other constructors:

* `PriorityChannel(Inf)`: equivalent to `Channel{Any}(typemax(Int))`
* `PriorityChannel(sz)`: equivalent to `Channel{Any}(sz)`
"""
mutable struct PriorityChannel{T,I} <: AbstractChannel{T}
    cond_take::Condition                 # waiting for data to become available
    cond_put::Condition                  # waiting for a writeable slot
    state::Symbol
    excp::Union{Exception, Nothing}         # exception to be thrown when state != :open

    data::Vector{PriorityElement{T,I}}
    sz_max::Int                          # maximum size of channel

    # Used when sz_max == 0, i.e., an unbuffered channel.
    waiters::Int
    takers::Vector{Task}
    putters::Vector{Task}

    function PriorityChannel{T,I}(sz::Float64) where {T,I<:Integer}
        if sz == Inf
            PriorityChannel{T,I}(typemax(Int))
        else
            PriorityChannel{T,I}(convert(Int, sz))
        end
    end
    function PriorityChannel{T,I}(sz::Integer) where {T,I<:Integer}
        if sz < 0
            throw(ArgumentError("Channel size must be either 0, a positive integer or Inf"))
        end
        ch = new(Condition(), Condition(), :open, nothing, Vector{PriorityElement{T,I}}(), sz, 0)
        if sz == 0
            ch.takers = Vector{Task}()
            ch.putters = Vector{Task}()
        end
        return ch
    end
end

PriorityChannel(sz) = PriorityChannel{Any,Int}(sz)

# special constructors
"""
    PriorityChannel(func::Function; ctype=Any, csize=0, taskref=nothing)

Create a new task from `func`, bind it to a new channel of type
`ctype` and size `csize`, and schedule the task, all in a single call.

`func` must accept the bound channel as its only argument.

If you need a reference to the created task, pass a `Ref{Task}` object via
keyword argument `taskref`.

Return a `Channel`.

# Examples
```jldoctest
julia> chnl = PriorityChannel(c->foreach(i->put!(c,i), 1:4));

julia> typeof(chnl)
Channel{Any}

julia> for i in chnl
           @show i
       end;
i = 1
i = 2
i = 3
i = 4
```

Referencing the created task:

```jldoctest
julia> taskref = Ref{Task}();

julia> chnl = PriorityChannel(c->(@show take!(c)); taskref=taskref);

julia> istaskdone(taskref[])
false

julia> put!(chnl, "Hello");
take!(c) = "Hello"

julia> istaskdone(taskref[])
true
```
"""
function PriorityChannel(func::Function; ctype=Any, csize=1, taskref=nothing)
    @assert csize >= 1 "PriorityChannel only supports positive sizes"
    chnl = PriorityChannel{ctype,Int}(csize)
    task = Task(() -> func(chnl))
    bind(chnl, task)
    yield(task) # immediately start it

    isa(taskref, Ref{Task}) && (taskref[] = task)
    return chnl
end


closed_exception() = InvalidStateException("Channel is closed.", :closed)

isbuffered(c::PriorityChannel) = true

function check_channel_state(c::PriorityChannel)
    if !isopen(c)
        c.excp !== nothing && throw(c.excp)
        throw(closed_exception())
    end
end
"""
    close(c::PriorityChannel)

Close a channel. An exception is thrown by:

* [`put!`](@ref) on a closed channel.
* [`take!`](@ref) and [`fetch`](@ref) on an empty, closed channel.
"""
function Base.close(c::PriorityChannel)
    c.state = :closed
    c.excp = closed_exception()
    notify_error(c)
    nothing
end
Base.isopen(c::PriorityChannel) = (c.state == :open)

"""
    bind(chnl::PriorityChannel, task::Task)

Associate the lifetime of `chnl` with a task.
`Channel` `chnl` is automatically closed when the task terminates.
Any uncaught exception in the task is propagated to all waiters on `chnl`.

The `chnl` object can be explicitly closed independent of task termination.
Terminating tasks have no effect on already closed `Channel` objects.

When a channel is bound to multiple tasks, the first task to terminate will
close the channel. When multiple channels are bound to the same task,
termination of the task will close all of the bound channels.

# Examples
```jldoctest
julia> c = PriorityChannel(0);

julia> task = @async foreach(i->put!(c, i), 1:4);

julia> bind(c,task);

julia> for i in c
           @show i
       end;
i = 1
i = 2
i = 3
i = 4

julia> isopen(c)
false
```

```jldoctest
julia> c = PriorityChannel(0);

julia> task = @async (put!(c,1);error("foo"));

julia> bind(c,task);

julia> take!(c)
1

julia> put!(c,1);
ERROR: foo
Stacktrace:
[...]
```
"""
function Base.bind(c::PriorityChannel, task::Task)
    ref = WeakRef(c)
    register_taskdone_hook(task, tsk->close_chnl_on_taskdone(tsk, ref))
    c
end

"""
    channeled_tasks(n::Int, funcs...; ctypes=fill(Any,n), csizes=fill(0,n))

A convenience method to create `n` channels and bind them to tasks started
from the provided functions in a single call. Each `func` must accept `n` arguments
which are the created channels. PriorityChannel types and sizes may be specified via
keyword arguments `ctypes` and `csizes` respectively. If unspecified, all channels are
of type `Channel{Any}(0)`.

Returns a tuple, `(Array{Channel}, Array{Task})`, of the created channels and tasks.
"""
function channeled_tasks(n::Int, funcs...; ctypes=fill(Any,n), csizes=fill(0,n))
    @assert length(csizes) == n
    @assert length(ctypes) == n

    chnls = map(i -> PriorityChannel{ctypes[i],Int}(csizes[i]), 1:n)
    tasks = Task[ Task(() -> f(chnls...)) for f in funcs ]

    # bind all tasks to all channels and schedule them
    foreach(t -> foreach(c -> bind(c, t), chnls), tasks)
    foreach(schedule, tasks)
    yield() # Allow scheduled tasks to run

    return (chnls, tasks)
end

function close_chnl_on_taskdone(t::Task, ref::WeakRef)
    if ref.value !== nothing
        c = ref.value
        !isopen(c) && return
        if istaskfailed(t)
            c.state = :closed
            c.excp = task_result(t)
            notify_error(c)
        else
            close(c)
        end
    end
end

"""
    put!(c::PriorityChannel, v)

Append an item `v` to the channel `c`. Blocks if the channel is full.

For unbuffered channels, blocks until a [`take!`](@ref) is performed by a different
task.

!!! compat "Julia 1.1"
    `v` now gets converted to the channel's type with [`convert`](@ref) as `put!` is called.
"""
function Base.put!(c::PriorityChannel{T,I}, v,i::I = 0) where {T,I<:Integer}
    check_channel_state(c)
    v = convert(T, v)
    while length(c.data) == c.sz_max
        wait(c.cond_put)
    end
    heappush!(c.data, PriorityElement(v,i))

    # notify all, since some of the waiters may be on a "fetch" call.
    notify(c.cond_take, nothing, true, false)
    v
end


Base.push!(c::PriorityChannel, v, i=0) = put!(c, v, i)

"""
    fetch(c::PriorityChannel)

Wait for and get the first available item from the channel. Does not
remove the item. `fetch` is unsupported on an unbuffered (0-size) channel.
"""
function Base.fetch(c::PriorityChannel)
    wait(c)
    c.data[end] # TODO: verify correct
end


"""
    take!(c::PriorityChannel)

Remove and return a value from a [`Channel`](@ref). Blocks until data is available.

For unbuffered channels, blocks until a [`put!`](@ref) is performed by a different
task.
"""
function Base.take!(c::PriorityChannel)
    wait(c)
    v = heappop!(c.data)
    notify(c.cond_put, nothing, false, false) # notify only one, since only one slot has become available for a put!.
    v
end

Base.popfirst!(c::PriorityChannel) = take!(c)

"""
    isready(c::PriorityChannel)

Determine whether a [`Channel`](@ref) has a value stored to it. Returns
immediately, does not block.

For unbuffered channels returns `true` if there are tasks waiting
on a [`put!`](@ref).
"""
Base.isready(c::PriorityChannel) = n_avail(c) > 0
n_avail(c::PriorityChannel) = length(c.data)

function Base.wait(c::PriorityChannel)
    while !isready(c)
        check_channel_state(c)
        wait(c.cond_take)
    end
    nothing
end


function notify_error(c::PriorityChannel, err)
    notify_error(c.cond_take, err)
    notify_error(c.cond_put, err)
end
notify_error(c::PriorityChannel) = notify_error(c, c.excp)

Base.eltype(::Type{PriorityChannel{T,I}}) where {T,I} = T

Base.show(io::IO, c::PriorityChannel) = print(io, "$(typeof(c))(sz_max:$(c.sz_max),sz_curr:$(n_avail(c)))")

function Base.iterate(c::PriorityChannel, state=nothing)
    try
        return (take!(c), nothing)
    catch e
        if isa(e, InvalidStateException) && e.state==:closed
            return nothing
        else
            rethrow()
        end
    end
end

Base.IteratorSize(::Type{<:Channel}) = SizeUnknown()


end # module
