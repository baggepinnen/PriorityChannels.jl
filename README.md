# PriorityChannels

[![Build Status](https://travis-ci.com/baggepinnen/PriorityChannels.jl.svg?branch=master)](https://travis-ci.com/baggepinnen/PriorityChannels.jl)

provides a type `PriorityChannel` that mimics `Base.Channel`, but where each element is associated with a priority. `take!` always returns the highest priority element. Internally, a heap is used to keep track of priorities. Example usage:
```julia
using PriorityChannels, Test
c  = Channel(50)
pc = PriorityChannel(50)
for i = 1:50
    e = rand(1:500)
    put!(c,e)
    put!(pc,e,e) # Assign same priority as element for testing purposes
end
elems = [take!(c) for i = 1:50]
pelems = [take!(pc) for i = 1:50]
@test !issorted(elems) # A regular Channel does not return ordered elements
@test issorted(pelems) # A PriorityChannel returns elements in priority order
```
