# Labelled spans around event indices and the point-wise labels they define.

"""
    fixed_spans(event_indices, fs, n; before, after) -> Vector{UnitRange{Int}}

Sample ranges `[i - before·fs, i + after·fs]` around the event sample
indices, clipped to `1:n` (`before`, `after` in seconds); the label window
of Isfan et al. (2025, doi:10.1088/1361-6382/ae1787) around a binary
merger, for example, is `before = 4 d`, `after = 27 min`.
"""
function fixed_spans(
    event_indices::AbstractVector{<:Integer},
    fs::Real,
    n::Integer;
    before::Real,
    after::Real,
)
    (before >= 0 && after >= 0) ||
        throw(ArgumentError("before and after must be non-negative."))
    fs > 0 || throw(ArgumentError("fs = $fs; the sampling frequency must be positive."))
    spans = UnitRange{Int}[]
    for i in event_indices
        1 <= i <= n || throw(ArgumentError("event index $i lies outside 1:$n."))
        push!(spans, max(1, i-round(Int, before*fs)):min(n, i+round(Int, after*fs)))
    end
    return spans
end

"""
    span_labels(n, spans) -> Vector{Int}

Point-wise labels of length `n`: 1 inside any of the sample ranges `spans`,
0 elsewhere.
"""
function span_labels(n::Integer, spans::AbstractVector{<:AbstractUnitRange{<:Integer}})
    labels = zeros(Int, n)
    for s in spans
        isempty(s) && continue
        (first(s) >= 1 && last(s) <= n) ||
            throw(ArgumentError("span $s lies outside 1:$n."))
        labels[s] .= 1
    end
    return labels
end
