# The interface between the conditioning chain of a
# streamed or recorded time series and the method applied to each window:
# estimators and their memory trait, scalar scorers for detection, and the
# spectral feature map of a conditioned window.

"""
    AbstractWindowEstimator

A method applied to one conditioned window of a time series (a detector
score, a parameter estimate, a posterior summary, a forecast). The chain
around it — delivery, gaps, window scheduling, conditioning, calibration,
evaluation — does not depend on the method. Concrete estimators declare
their memory with [`estimator_memory`](@ref).
"""
abstract type AbstractWindowEstimator end

"""
    AbstractWindowScorer <: AbstractWindowEstimator

An estimator whose output is one scalar score per window, larger meaning
more evidence for the event class, bounded by [`score_bounds`](@ref). The
detection chain (threshold, persistence, crediting) acts on it. A scorer
implements [`window_score`](@ref).
"""
abstract type AbstractWindowScorer <: AbstractWindowEstimator end

"""
    EstimatorMemory

Memory trait of an [`AbstractWindowEstimator`](@ref): [`Stateless`](@ref)
or [`Stateful`](@ref).
"""
abstract type EstimatorMemory end

"""
    Stateless()

An estimator whose output for a window depends on that window alone, so
windows may be evaluated in any order, as they complete.
"""
struct Stateless <: EstimatorMemory end

"""
    Stateful()

An estimator that carries state from window to window (a reservoir, a
sequential posterior) and so must see the windows in content order, each
once, with every hole declared.
"""
struct Stateful <: EstimatorMemory end

"""
    estimator_memory(estimator) -> EstimatorMemory

[`Stateless`](@ref) unless an estimator declares otherwise.
"""
estimator_memory(::AbstractWindowEstimator) = Stateless()

"""
    window_score(scorer, window, sample_rate) -> Float32

Score of one conditioned `window` (samples at `sample_rate` [Hz]): a
vector, or in a replay of several synchronous channels a matrix with one
column per channel. Implemented by every concrete
[`AbstractWindowScorer`](@ref); the fallbacks throw an `ArgumentError`
naming the scorer type.
"""
function window_score end

window_score(scorer::AbstractWindowScorer, ::AbstractVector{<:Real}, ::Real) =
    throw(ArgumentError("$(typeof(scorer)) does not implement window_score."))
window_score(scorer::AbstractWindowScorer, ::AbstractMatrix{<:Real}, ::Real) = throw(
    ArgumentError(
        "$(typeof(scorer)) does not implement window_score for a window of several channels.",
    ),
)

"""
    score_label(scorer) -> String

Axis label of the score in figures; `"Score"` unless a scorer declares
otherwise.
"""
score_label(::AbstractWindowScorer) = "Score"

"""
    score_bounds(scorer) -> Tuple{Float64,Float64}

Range of the score; `(0.0, 1.0)` unless a scorer declares otherwise.
"""
score_bounds(::AbstractWindowScorer) = (0.0, 1.0)

"""
    FeatureMap(; feature_set = :whitened, low_band = (1e-3, 5e-3),
               high_band = (5e-3, 1e-1), band_edges = [1e-3, 5e-3, 1e-1],
               combination = :mean)

The spectral features of a conditioned window ([`extract_features`](@ref)):
the feature set and its analysis bands [Hz]. `band_edges` is validated
([`check_band_edges`](@ref)) for every set, as the conditioning of a run
records it, and used only by the `:bands` set. `combination` says how the
channels of a multichannel window enter ([`CHANNEL_COMBINATIONS`](@ref))
and has no effect on a single channel.
"""
struct FeatureMap
    feature_set::Symbol
    low_band::Tuple{Float64,Float64}
    high_band::Tuple{Float64,Float64}
    band_edges::Vector{Float64}
    combination::Symbol
    function FeatureMap(;
        feature_set::Symbol = :whitened,
        low_band::Tuple{Real,Real} = (1e-3, 5e-3),
        high_band::Tuple{Real,Real} = (5e-3, 1e-1),
        band_edges::AbstractVector{<:Real} = [1e-3, 5e-3, 1e-1],
        combination::Symbol = :mean,
    )
        feature_set in FEATURE_SETS || throw(
            ArgumentError("feature_set = $feature_set; expected one of $(FEATURE_SETS)."),
        )
        combination in CHANNEL_COMBINATIONS || throw(
            ArgumentError(
                "combination = :$combination; expected one of $(CHANNEL_COMBINATIONS).",
            ),
        )
        return new(
            feature_set,
            (Float64(low_band[1]), Float64(low_band[2])),
            (Float64(high_band[1]), Float64(high_band[2])),
            check_band_edges(band_edges),
            combination,
        )
    end
end

"""
    extract_features(map::FeatureMap, window, sample_rate) -> Tuple

Features of `window` under the set and bands of `map`.
"""
function extract_features(
    map::FeatureMap,
    window::AbstractVecOrMat{<:Real},
    sample_rate::Real,
)
    return extract_features(
        window,
        sample_rate;
        low_band = map.low_band,
        high_band = map.high_band,
        band_edges = map.band_edges,
        feature_set = map.feature_set,
        combination = map.combination,
    )
end

"""
    reset_estimator!(estimator)

Return a [`Stateful`](@ref) estimator to its initial state; a replay calls
it once before its first window. A no-op unless an estimator implements it.
"""
reset_estimator!(::AbstractWindowEstimator) = nothing

"""
    GapEvent(first_window, last_window, cause, declared_at)

A run of consecutive windows `first_window:last_window` that a
[`Stateful`](@ref) estimator will not see, declared at mission time
`declared_at` before the first window after it is released. `cause` is
`:lost` (the window's own rows, or more of its conditioning stretch than
the coverage bound admits, fell in a lost or pruned batch), `:undelivered`
(not delivered by the end of the record), or `:horizon` (not delivered
within the order horizon while later windows were waiting).
"""
struct GapEvent
    first_window::Int
    last_window::Int
    cause::Symbol
    declared_at::Dates.DateTime
    function GapEvent(
        first_window::Integer,
        last_window::Integer,
        cause::Symbol,
        declared_at::Dates.DateTime,
    )
        1 <= first_window <= last_window || throw(
            ArgumentError(
                "gap of windows $first_window:$last_window; need 1 <= first <= last.",
            ),
        )
        cause in (:lost, :undelivered, :horizon) || throw(
            ArgumentError("gap cause $cause; expected :lost, :undelivered, or :horizon."),
        )
        return new(Int(first_window), Int(last_window), cause, declared_at)
    end
end

"""
    estimator_gap!(estimator, gap::GapEvent)

Inform a [`Stateful`](@ref) estimator that the windows of `gap` will not
be seen, before the first window after it; the estimator decides whether
to reset, bridge, or record the hole. A no-op unless an estimator
implements it.
"""
estimator_gap!(::AbstractWindowEstimator, ::GapEvent) = nothing
