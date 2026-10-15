# StreamingInference.jl

Windowed analysis of a time series that is delivered in batches: late, out
of order, and with permanent holes. The package keeps track of which part
of the record is on the ground, schedules each window once the stretch
around it has arrived, conditions it by high-pass filtering and by
whitening with a given noise power spectral density (PSD) or with a causal
estimate of it, and passes it to an estimator. Evaluation acts on what the
estimator returns: thresholds chosen on a calibration block, event-level
metrics, false-alarm rates and alert latencies.

The estimator is supplied by the user. Nothing in the package depends on a
physical domain or on a particular method; a detector score, a parameter
estimate or a forecast plug into the same chain.

A record may hold several synchronous channels. The payload is then a
matrix with one column per channel, every batch delivers all channels
together, each channel is whitened by its own PSD, and the scorer receives
a matrix window with one column per channel.
[`ScheduledRecordRun`](@ref) applies the delivery of a one-column run to a
local multichannel record.

## Installation and status

The package works on its own. It is the domain-general base of a set of
three packages: [MilliHertzBase.jl](https://github.com/PaulGoG/MilliHertzBase.jl)
builds on it the gravitational-wave layer for the Laser Interferometer
Space Antenna (LISA), and
[MilliHertzQML.jl](https://github.com/PaulGoG/MilliHertzQML.jl), a
variational quantum classifier, builds on both. It requires Julia 1.13 or
later and is not registered; its first release is 0.1.0 (tag `v0.1.0`,
15 October 2026), and an environment adds it by URL at the tag or
following `main`:

```julia
using Pkg
Pkg.add(url = "https://github.com/PaulGoG/StreamingInference.jl", rev = "v0.1.0")  # the release
Pkg.add(url = "https://github.com/PaulGoG/StreamingInference.jl")                  # main
```

The figures need `CairoMakie` in the same environment; the runs of the
telemetry simulator DeepSpaceTelemetry.jl, unregistered as well, open once
its version 2.6 or later is loaded too ([DeepSpaceTelemetry runs](@ref)).

## Layout of the package

| Part | Contents |
|---|---|
| Estimators | `AbstractWindowEstimator`, the scalar `AbstractWindowScorer` with `window_score`, `score_label`, `score_bounds`; the memory trait `estimator_memory` (`Stateless`, `Stateful`); `GapEvent`, `estimator_gap!`, `reset_estimator!`; the spectral `FeatureMap` of a conditioned window |
| Streaming replay | the run interface (`AbstractTelemetryRun`, `MemoryTelemetryRun`, `ScheduledRecordRun`), `Coverage`, `WindowScheduler`, `StreamingDetector`, `condition_window`, `TrailingWelch`, `replay_run`, `follow_run`, `replay_state`, `windows_table`, `gaps_table`, `alert_latency_table`, `window_overlap` |
| Signal processing | `synthesize_noise`, `tapered_periodogram`, `network_periodogram`, `welch_psd`, `smooth_psd`, `interpolated_psd`, `highpass_record`, `whiten_record`, `matched_filter_snr`, `scale_to_snr`, `place_signal!` |
| Features and labels | `extract_features`, `window_features`, `window_labels`, `finite_stretches`, `window_indices`, `fixed_spans`, `span_labels`, `chronological_split` |
| Evaluation | `roc_curve`, `roc_auc`, `contiguous_runs`, `event_metrics`, `threshold_sweep`, `select_threshold` |
| Configuration and provenance | `load_config`, `cfgget`, `section`, `with_pipeline_root`, `config_root`, `project_root`, `resolvepath`, `provenance`, `git_provenance`, `layer_provenance`, `hardware_fingerprint`, `parameter_digest`, `content_digest`, `product_table`, `recorded_channels` |
| Figures (CairoMakie extension) | `figure_theme`, `save_figure`, `figure_roc`, `figure_threshold_sweep`, `figure_sensitivity`, `figure_score_distribution`, `figure_telemetry_alerts`, `animate_mission_replay` |

## Example

A replay of an in-memory run through a scorer that returns the RMS of the
whitened window:

```julia
using StreamingInference, Dates, Random

# Whitened noise has unit variance: its RMS lies near 1, and the score has
# no upper bound.
struct RMSScorer <: AbstractWindowScorer end
StreamingInference.window_score(::RMSScorer, w::AbstractVector{<:Real}, ::Real) =
    Float32(sqrt(sum(abs2, w) / length(w)))
StreamingInference.score_bounds(::RMSScorer) = (0.0, Inf)

fs = 0.2                                     # sampling rate [Hz]
psd(f) = 1e-40 * (1 + (1e-3 / f)^2)          # one-sided noise PSD [1/Hz]
payload = synthesize_noise(Xoshiro(3), 8000, fs; psd = psd, f_min = 1e-5)

# 80 batches of 10 segments of 50 s, one delivered every 10 minutes
geometry = RunGeometry(fs, 50.0, 10, DateTime(2035), "example")
events = [ArrivalEvent(DateTime(2035) + Second(600k), "LIVE_batch_$k", :ingested, 0) for k in 1:80]
run = MemoryTelemetryRun(geometry, payload, events)

detector = StreamingDetector(RMSScorer(), 1.5; sample_rate = fs, window_size = 1000,
                             step_size = 100, psd = psd, context_windows = 1)
windows = replay_run(run, detector)          # one row per scored window
lo, hi = extrema(windows.score)
println(size(windows, 1), " windows, scores ", round(lo; digits = 2), " to ",
        round(hi; digits = 2), ", alarms ", sum(windows.decision))
# 71 windows, scores 0.97 to 1.04, alarms 0: no window of noise reaches 1.5
```

[Streaming replay](replay.md) describes the time model behind
`replay_run`; the [API reference](api.md) lists every name.
