# PriorityChannels

[![Build Status](https://travis-ci.org/baggepinnen/PriorityChannels.jl.svg?branch=master)](https://travis-ci.org/baggepinnen/PriorityChannels.jl)

This package provides the type `PriorityChannel` (the only exported name) that mimics [`Base.Channel`](https://docs.julialang.org/en/v1/base/parallel/#Base.Channel), but where each element is associated with a priority. [`take!`](https://docs.julialang.org/en/v1/base/parallel/#Base.take!-Tuple{Channel}) always returns the highest priority element. Internally, a [heap](https://en.wikipedia.org/wiki/Heap_(data_structure)) is used to keep track of priorities. Example usage:
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

## Difference between `Channel` and `PriorityChannel`
- `put!(pc, element, priority::Real)` **lower** number indicates a higher priority (default = 0).
- `PriorityChannel` can not be unbuffered (of length 0) and must have a positive length.
- [`take!(pc)`](https://docs.julialang.org/en/v1/base/parallel/#Base.take!-Tuple{Channel}) returns the highest priority item, `PriorityChannel` thus acts like a  [priority queue](https://en.wikipedia.org/wiki/Priority_queue) instead of a FIFO queue like `Channel` does
- Pretty much all other functionality should be the same, including all constructors.
