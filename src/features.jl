# Spectral features of a conditioned window and loading of feature and label
# tables.

"""
    FEATURE_SETS

The feature sets of [`extract_features`](@ref): `:whitened` (two band
powers, entropy, log power spread), `:paper` (the raw-window moments of
Isfan et al. 2025), and `:bands` (one power per band between consecutive
`band_edges`, entropy, log power spread).
"""
const FEATURE_SETS = (:whitened, :paper, :bands)

"""
    CHANNEL_COMBINATIONS

How [`extract_features`](@ref) combines the synchronous channels of a
window: `:mean` (features of the channel-averaged periodogram) or `:max`
(the features of every channel, combined by the value farthest towards a
signal).
"""
const CHANNEL_COMBINATIONS = (:mean, :max)

"""
    feature_names(feature_set; n_bands = 2) -> Vector{Symbol}

Column names of the feature table produced by [`extract_features`](@ref)
for `feature_set`; `n_bands` is the number of bands of the `:bands` set
(one less than the number of edges) and is ignored otherwise.
"""
function feature_names(feature_set::Symbol; n_bands::Integer = 2)
    feature_set == :whitened && return [:p_low, :p_high, :spectral_entropy, :log_power_std]
    feature_set == :paper &&
        return [:spectral_entropy, :log_power_mean, :log_power_std, :log_power_max]
    if feature_set == :bands
        n_bands >= 1 || throw(ArgumentError("n_bands = $n_bands; at least 1."))
        return vcat(
            [Symbol("p_band_$i") for i in 1:n_bands],
            [:spectral_entropy, :log_power_std],
        )
    end
    throw(ArgumentError("feature_set = $feature_set; expected one of $(FEATURE_SETS)."))
end

"""
    check_band_edges(band_edges)

Validates the edges of the `:bands` feature set: at least two strictly
ascending positive frequencies [Hz]. Returns them as `Vector{Float64}`.
"""
function check_band_edges(band_edges)
    (
        band_edges isa AbstractVector &&
        length(band_edges) >= 2 &&
        all(e -> e isa Real && isfinite(e), band_edges) &&
        band_edges[1] > 0 &&
        all(band_edges[i] < band_edges[i+1] for i in 1:(length(band_edges)-1))
    ) || throw(
        ArgumentError(
            "band_edges = $(repr(band_edges)); expected at least two strictly ascending " *
            "positive frequencies [Hz].",
        ),
    )
    return Float64.(band_edges)
end

"""
    extract_features(x, sample_rate = 0.2; low_band = (1e-3, 5e-3),
                     high_band = (5e-3, 1e-1), band_edges = nothing, taper = :hann,
                     feature_set = :whitened, combination = :mean)

Feature vector of a window `x` sampled at `sample_rate` [Hz], computed
from its tapered periodogram ``P_k`` ([`tapered_periodogram`](@ref)).
Returns a tuple of `Float32` whose entries are named by
[`feature_names`](@ref).

A matrix `x` holds a window of several synchronous channels, one per
column, and `combination` says how they enter; either way the number of
features does not depend on the number of channels.

- `:mean` (default): the features of the channel-averaged periodogram
  ([`network_periodogram`](@ref)), the excess power of the network. It is
  the best incoherent statistic for a signal split equally between the
  channels, and dilutes one that a single channel sees: its excess power is
  divided by the number of channels while the noise spread falls only as
  the root of it.
- `:max`: the features of every channel, combined by the value that lies
  farthest towards a signal — the largest band power and power spread (and,
  for `:paper`, mean and maximum), the smallest entropy. A signal seen by
  one channel keeps its features; the noise level of a maximum over ``C``
  channels is higher than that of one, a trials factor.

`feature_set = :whitened` (the default) expects a window of the
**whitened** record ([`whiten_record`](@ref)), whose periodogram has unit
mean for noise and is therefore independent of window length and noise
amplitude:

1. mean whitened power in `low_band` [Hz];
2. mean whitened power in `high_band` [Hz];
3. spectral entropy of the normalised whitened power, divided by
   ``\\ln N_\\mathrm{bins}`` so that it lies in ``[0, 1]``;
4. ``\\log_{10}`` of the standard deviation of the whitened power (0 for
   white noise, whose periodogram is exponentially distributed).

`feature_set = :bands` generalises the whitened set to the bands between
consecutive `band_edges` [Hz] (the first band closed on both sides, the
others open at their lower edge): the mean whitened power of every band,
then the entropy and the log power spread as above — `length(band_edges)
+ 1` features. With the edges `[1e-3, 5e-3, 1e-1]` it reproduces the
whitened set exactly.

`feature_set = :paper` is the set of Isfan et al. (2025) on the raw window:
the normalised spectral entropy and ``\\log_{10}`` of the mean, standard
deviation, and maximum of the periodogram (the paper uses the raw
moments; the logarithm is a monotone transform that keeps their min–max
scaling well conditioned over the many decades a noise spectrum can span).

Throws an `ArgumentError` when an analysis band holds no frequency bin.
"""
function extract_features(
    x::AbstractVecOrMat{<:Real},
    sample_rate::Real = 0.2;
    low_band::Tuple{Real,Real} = (1e-3, 5e-3),
    high_band::Tuple{Real,Real} = (5e-3, 1e-1),
    band_edges::Union{Nothing,AbstractVector{<:Real}} = nothing,
    taper::Symbol = :hann,
    feature_set::Symbol = :whitened,
    combination::Symbol = :mean,
)
    sample_rate > 0 || throw(ArgumentError("sample_rate = $sample_rate; must be positive."))
    feature_set in FEATURE_SETS ||
        throw(ArgumentError("feature_set = $feature_set; expected one of $(FEATURE_SETS)."))
    combination in CHANNEL_COMBINATIONS || throw(
        ArgumentError(
            "combination = :$combination; expected one of $(CHANNEL_COMBINATIONS).",
        ),
    )
    if combination == :max && x isa AbstractMatrix && size(x, 2) > 1
        per_channel = [
            extract_features(
                @view(x[:, c]),
                sample_rate;
                low_band = low_band,
                high_band = high_band,
                band_edges = band_edges,
                taper = taper,
                feature_set = feature_set,
            ) for c in axes(x, 2)
        ]
        names = feature_names(feature_set; n_bands = max(length(per_channel[1]) - 2, 1))
        # The entropy falls when a signal concentrates the power; every
        # other feature rises with it
        return ntuple(
            j ->
                names[j] == :spectral_entropy ? minimum(f[j] for f in per_channel) :
                maximum(f[j] for f in per_channel),
            length(names),
        )
    end
    edges = feature_set == :bands ? check_band_edges(band_edges) : Float64[]
    power = network_periodogram(x; taper = taper)
    n_samples = size(x, 1)

    total = sum(power)
    n_bins = length(power) - 1   # the DC bin carries no power
    entropy = 0.0
    if total > 0 && n_bins > 1
        for p in power
            p > 0 || continue
            q = p / total
            entropy -= q * log(q)
        end
        entropy /= log(n_bins)
    end
    positive = @view power[2:end]
    log_power_std = log10(std(positive) + 1e-300)

    if feature_set == :paper
        log_power_mean = log10(mean(positive) + 1e-300)
        log_power_max = log10(maximum(positive) + 1e-300)
        return Float32(entropy),
        Float32(log_power_mean),
        Float32(log_power_std),
        Float32(log_power_max)
    end

    freqs = rfftfreq(n_samples, sample_rate)
    if feature_set == :bands
        n_bands = length(edges) - 1
        p_bands = Vector{Float32}(undef, n_bands)
        for i in 1:n_bands
            lower = i == 1 ? (freqs .>= edges[i]) : (freqs .> edges[i])
            mask = lower .& (freqs .<= edges[i+1])
            any(mask) || throw(
                ArgumentError(
                    "window of $n_samples samples at $sample_rate Hz has no frequency bin " *
                    "in the band $(edges[i])–$(edges[i+1]) Hz; use a longer window or wider bands.",
                ),
            )
            p_bands[i] = Float32(mean(@view power[mask]))
        end
        return (p_bands..., Float32(entropy), Float32(log_power_std))
    end
    mask_low = (freqs .>= low_band[1]) .& (freqs .<= low_band[2])
    mask_high = (freqs .> high_band[1]) .& (freqs .<= high_band[2])
    (any(mask_low) && any(mask_high)) || throw(
        ArgumentError(
            "window of $n_samples samples at $sample_rate Hz has no frequency bins " *
            "in the $(low_band) Hz or $(high_band) Hz analysis bands; use a longer window.",
        ),
    )
    p_low = mean(@view power[mask_low])
    p_high = mean(@view power[mask_high])
    return Float32(p_low), Float32(p_high), Float32(entropy), Float32(log_power_std)
end

"""
    network_periodogram(x; taper = :hann) -> Vector{Float64}

Tapered periodogram of a window ([`tapered_periodogram`](@ref)); for a
matrix `x` of ``C`` synchronous channels, one per column, the average over
the channels, ``\\bar P_k = \\frac{1}{C} \\sum_c P_k^{(c)}``. On channels
whitened one by one, with independent noise, every ``P_k^{(c)}`` has unit
mean under noise and ``\\bar P_k`` keeps it while its variance falls as
``1/C``; the power of a signal adds over the channels, as the squared
signal-to-noise ratios of a network do.
"""
network_periodogram(x::AbstractVector{<:Real}; taper::Symbol = :hann) =
    tapered_periodogram(x; taper = taper)

function network_periodogram(x::AbstractMatrix{<:Real}; taper::Symbol = :hann)
    n_channels = size(x, 2)
    n_channels >= 1 || throw(ArgumentError("the window holds no channel."))
    power = tapered_periodogram(@view(x[:, 1]); taper = taper)
    for c in 2:n_channels
        power .+= tapered_periodogram(@view(x[:, c]); taper = taper)
    end
    n_channels > 1 && (power ./= n_channels)
    return power
end

"""
    load_features(feature_path) -> Matrix{Float32}

Raw feature matrix (samples × features) from a feature CSV written by a
pre-processing stage. Any encoding for an estimator is a separate step, so
that a scaler fitted on the training partition is applied identically at
inference.
"""
function load_features(feature_path::AbstractString)
    return Matrix{Float32}(CSV.read(feature_path, DataFrame))
end

"""
    load_data(feature_path, label_path) -> (X, y, df_labels)

Raw feature matrix, integer label vector, and the full label table (which
retains auxiliary columns such as `SNR`) from the CSVs written by
`scripts/preprocess_ldc.jl`.
"""
function load_data(feature_path::AbstractString, label_path::AbstractString)
    X = load_features(feature_path)
    df_labels = CSV.read(label_path, DataFrame)
    y = Int.(df_labels[:, :Label])
    size(X, 1) == length(y) ||
        throw(DimensionMismatch("$(size(X, 1)) feature rows but $(length(y)) labels."))
    return X, y, df_labels
end
