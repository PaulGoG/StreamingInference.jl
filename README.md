# StreamingInference.jl

[![CI](https://github.com/PaulGoG/StreamingInference.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/PaulGoG/StreamingInference.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/PaulGoG/StreamingInference.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/PaulGoG/StreamingInference.jl)
[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://PaulGoG.github.io/StreamingInference.jl/dev/)
[![Julia](https://img.shields.io/badge/julia-%E2%89%A5%201.13-9558B2)](https://julialang.org/)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Windowed analysis of a time series that arrives in batches, late, out of
order and with gaps. The package schedules windows over whatever part of
the record has been delivered, conditions each window (high-pass,
whitening by a static or a causal Welch PSD estimate), hands it to an
estimator, and evaluates the result: thresholds, event-level metrics, alert
latencies. The estimator is a type you supply; nothing here depends on a
physical domain or on a particular method.

It is the base of a set of three packages. I wrote this code as the
domain-general layer of
[MilliHertzQML.jl](https://github.com/PaulGoG/MilliHertzQML.jl), a
quantum classifier for gravitational-wave telemetry, and moved it into its
own package so that other pipelines (other estimators, other kinds of
series) can share the same streaming, provenance and evaluation code;
[MilliHertzBase.jl](https://github.com/PaulGoG/MilliHertzBase.jl), the
gravitational-wave layer, builds on it. The manual is built from `main` at
[PaulGoG.github.io/StreamingInference.jl/dev](https://PaulGoG.github.io/StreamingInference.jl/dev/).

```
StreamingInference.jl/
├── activate.jl                 # activates and instantiates the package environment
├── src/
│   ├── StreamingInference.jl   # module and public names
│   ├── estimators.jl           # estimator interface: scorers, memory trait, gaps
│   ├── telemetry.jl            # run interface, coverage, scheduling, replay, alerts
│   ├── dsp.jl                  # periodograms, Welch PSD, whitening, high-pass
│   ├── evaluation.jl           # ROC, event metrics, threshold selection
│   ├── config.jl               # TOML configuration and the pipeline root
│   └── provenance.jl           # run identifiers, git and hardware provenance, digests
├── ext/                        # CairoMakie (figures) and DeepSpaceTelemetry (producer runs) extensions
├── test/                       # suite with static QA, own environment
└── docs/                       # Documenter manual, own environment
```

The full tree is at the end of this page.

## Installation

The package requires Julia 1.13 or later and is not registered. There is
no release yet: an environment adds it from this repository, following
`main` or pinned to a commit with `rev`:

```julia
using Pkg
Pkg.add(url = "https://github.com/PaulGoG/StreamingInference.jl")
```

The figures need `CairoMakie` in the same environment. Runs of the
[DeepSpaceTelemetry](https://github.com/PaulGoG/DeepSpaceTelemetry.jl)
producer open with `open_telemetry_run` once DeepSpaceTelemetry 2.6 or
later is loaded beside this package.

## Entry points

```sh
julia -i activate.jl          # REPL in the package environment (activates and instantiates it)
julia test/runtests.jl        # test suite, with Aqua, JET and ExplicitImports
julia docs/make.jl            # manual, built into docs/build/
```

Each environment (the root, `test/`, `docs/`) has an `activate.jl` that
activates and instantiates it, and every entry point includes its own
first.

## Example

A replay of an in-memory run through a scorer that returns the RMS of the
whitened window:

```julia
using StreamingInference, Dates, Random

struct RMSScorer <: AbstractWindowScorer end
StreamingInference.window_score(::RMSScorer, w::AbstractVector{<:Real}, ::Real) =
    Float32(sqrt(sum(abs2, w) / length(w)))

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
```

`windows` holds, per window, its content span, the time its conditioning
stretch was complete on the ground, the score and the decision. The
manual describes the time model, stateful estimators (ordered release,
declared gaps), causal whitening (`TrailingWelch`), threshold selection
and the alert tables.

## Status

No release yet: version 0.1.0-DEV on `main`, which MilliHertzBase.jl and
MilliHertzQML.jl pin by commit. The code was the domain-general layer of
MilliHertzQML.jl until the layers were separated into packages on
1 October 2026; the repository keeps the history of those files. Known
limitations, inherited from that origin and to be generalised:

- the event tables of `alert_latency_table` and `event_merger_times` name
  the event time `merger_time_s` (or `t_c_sec`);
- the run interface follows the batch naming of the DeepSpaceTelemetry
  producer (`LIVE_batch_<k>`, `ARCH_batch_<k>`), and `replay_run` keeps a
  `tdi_gap_dilation_sec` keyword;
- the default high-pass cutoff of `StreamingDetector` (0.5 mHz) suits the
  millihertz band of its origin; set it for other series.

## Full file tree

<details>
<summary>Full file tree</summary>

```
StreamingInference.jl/
├── Project.toml                # Package metadata, dependencies, compat (Julia ≥ 1.13)
├── activate.jl                 # Activates and instantiates the package environment
├── CHANGELOG.md
├── CITATION.cff
├── LICENSE
├── src/
│   ├── StreamingInference.jl   # Module, exported and public names
│   ├── config.jl               # TOML configuration, pipeline root, path helpers, settings sections
│   ├── provenance.jl           # Run identifiers, git and hardware provenance, manifests, digests
│   ├── dsp.jl                  # Noise synthesis, periodograms, Welch PSD, smoothing, whitening, high-pass
│   ├── features.jl             # Band-power features of a window, feature names
│   ├── spans.jl                # Labelled spans around event samples
│   ├── evaluation.jl           # ROC, contiguous runs, event metrics, threshold sweep and selection
│   ├── windows.jl              # Window geometry of a record
│   ├── estimators.jl           # Estimator interface, memory trait, feature map, gap events
│   ├── visualization.jl        # Figure interface and the shared figure toolkit
│   └── telemetry.jl            # Run interface, coverage, scheduler, detector, replay, alert tables
├── ext/
│   ├── StreamingInferenceCairoMakieExt.jl  # Theme, exports, evaluation, score and replay figures
│   └── StreamingInferenceDeepSpaceTelemetryExt.jl  # Producer runs through its reference run adapter
├── test/
│   ├── Project.toml            # Test environment (package by path, DeepSpaceTelemetry by commit)
│   ├── activate.jl
│   ├── runtests.jl             # Static QA, signal processing, evaluation, configuration, figures
│   ├── telemetry_tests.jl      # Streaming replay, reference scorers, ordered release
│   ├── hole_tests.jl           # Holes declared by the producer
│   └── deepspacetelemetry_tests.jl  # Producer missions on the tick clock, derived run directories
├── docs/
│   ├── Project.toml            # Documentation environment (package by path)
│   ├── activate.jl
│   ├── make.jl
│   └── src/                    # Manual pages
├── .github/
│   ├── workflows/CI.yml        # Tests on the compat floor and the current release, formatting check, coverage
│   ├── workflows/Documentation.yml  # Manual built on every push, deployed to GitHub Pages
│   └── dependabot.yml          # Weekly updates of the Julia and GitHub Actions dependencies
└── codecov.yml                 # Coverage statuses informational; the commit status rests on the tests
```

</details>

## How to cite

`CITATION.cff` carries the metadata; in BibTeX:

```bibtex
@software{Gogita_StreamingInference_jl,
  author = {Gogîță, Paul-Adrian},
  title  = {{StreamingInference.jl}},
  url    = {https://github.com/PaulGoG/StreamingInference.jl},
  year   = {2026}
}
```

## License

MIT; see `LICENSE`.
