# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- First release as a package of its own. The code was the domain-general
  layer of MilliHertzQML.jl (3.0.0-DEV) and keeps its history from the
  commit that separated the layers: the estimator interface and stateful
  estimators with ordered release, the streaming replay and its run
  interface, causal whitening, signal processing, features, evaluation and
  threshold selection, configuration with an explicit pipeline root,
  provenance and SHA-256 product identity, and the CairoMakie extension
  with the theme, exports and figures of this layer.
- `layer_provenance` lists the packages of the pipeline — this one and
  every package of the resolved environment that depends on it — with the
  version and the tree hash, revision or path each is tracked by;
  `provenance` records it under `layers`.
- Windows of several synchronous channels: `extract_features` and
  `window_features` take a matrix with one channel per column and return
  the features of the channel-averaged tapered periodogram
  (`network_periodogram`), so the feature dimension does not depend on the
  number of channels; one channel as a matrix gives the features of the
  vector bit for bit.

### Changed (relative to the layer inside MilliHertzQML.jl)
- The score figures no longer assume a classifier probability: `figure_roc`
  takes the scorer's name as `label`; `figure_score_distribution`,
  `figure_telemetry_alerts` and `animate_mission_replay` take
  `score_label`, `score_name`, `event_label` and `score_range`, and their
  score axes span the scores and the threshold unless `score_range` is
  given.
- `git_provenance` records the version of the package at the pipeline root
  (`package_version`, from its `Project.toml`) and this package's version
  (`streaminference_version`); inside MilliHertzQML.jl both were one.
- `window_score` has a fallback for `AbstractWindowScorer` that throws an
  `ArgumentError` naming a scorer type without a method.
