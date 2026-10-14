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
  vector bit for bit. `combination = :max` (`CHANNEL_COMBINATIONS`)
  computes the features of every channel instead and keeps, of each, the
  value farthest towards a signal, so that a signal seen by one channel
  only is not diluted by the others.
- The replay of several synchronous channels: `read_batch` may return a
  matrix with one column per channel (the delivery of a batch is common to
  its channels), `MemoryTelemetryRun` takes such a payload,
  `condition_window` conditions every channel on its own with the PSD of
  its position in the detector's `psd` (a tuple or vector, one per channel),
  a `TrailingWelch` replay keeps one causal estimate per channel, and the
  scorer receives the window as a matrix. `FeatureMap` carries the
  `combination` of the channels. A single-channel replay is unchanged.
  `ScheduledRecordRun` applies the delivery of one run to the content of a
  local record of several channels, after checking that the record is the
  content the run carried.
- `recorded_channels` reads the channel set a product was made from out of
  its sidecar, with a default for the products that record none.
- Records with gaps: `finite_stretches` gives the stretches of a record
  between samples marked `NaN`; `window_indices` the record window index of
  every row of a feature table, which jumps between the stretches of such
  a product (`stretches` in its sidecar); `contiguous_runs` and
  `event_metrics` take those indices (`windows`) and end events and
  false-alarm episodes at a gap instead of running across it.
- A DeepSpaceTelemetry extension (DeepSpaceTelemetry 2.6 or later):
  `open_telemetry_run` opens a producer run directory through the
  producer's reference run adapter, `RunAdapter`, with the version floor
  `producer_compat`, the refusal of external-payload runs of producers up
  to 2.0.1 that hold a generation gap or an emitter restart, and the
  refusal of a payload row 1 away from the mission epoch. `columns` selects
  the payload columns of a run that carries several under one link
  accounting: the only column by default, one by name as a vector, several
  by name as the channels of a matrix. The rows of a batch follow the
  payload row the producer stamps (2.1.0 and later), checked against its
  content epoch, and its content epoch for earlier producers. This
  adapter was the DeepSpaceTelemetry extension of MilliHertzBase.jl, built
  on the producer's internal readers; nothing in it was specific to
  gravitational waves.
- Holes declared by the producer: `DeclaredHole` (cause, batch, rows,
  declaration instant; `HOLE_CAUSES`, `hole_cause`) and the run interface
  function `declared_holes(run; after)`, empty by default; the extension
  reads the producer's declared-hole feed (`holes.csv`, 2.6.0 and later)
  and, for earlier producers, the generation gaps of its event logs. A
  replay consumes arrivals and declarations in mission-time order
  (`process_hole!`): the rows of a declared hole become a permanent hole
  from its declaration, widened by `tdi_gap_dilation_sec` like a lost
  batch, and a stateful estimator is told of the windows it settles at
  once, with the producer's cause (`GapEvent` causes `:scheduled`,
  `:recorder`, `:stream`, `:not_generated`, `:other`; `GAP_CAUSES`),
  instead of `:undelivered` at the end of the record.
- `record_final(run)`: whether the arrival feed and the declared holes are
  final, by default once the run is no longer active; the extension
  reports a run final while the producer post-processes.
  `batch_records(run, names)` resolves named batches, by default from one
  listing; `run_descriptor(run)` returns the producer's identity of the
  run (`descriptor.toml` in the extension), empty by default.

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

### Changed
- `follow_run` polls the declared holes beside the arrival feed, resolves
  only the batches its fresh arrivals name (`batch_records`) instead of
  listing the run on every poll, polls again at once while the feeds
  deliver, and stops once the record is final (`record_final`) and both
  feeds are drained, rather than when the run leaves the active state:
  a live replay now ends when the data end, not when the producer has
  finished its figures.
- `ScheduledRecordRun` resolves a batch its schedule delivers after the
  run was wrapped, so that it serves a followed run.
- Replays of runs whose producer declares generation gaps change at the
  edges of those gaps: the declared rows are widened by the erosion, so
  the window whose conditioning stretch begins within `tdi_gap_dilation_sec`
  after a gap is no longer scored. Runs without declared holes replay
  unchanged.
- `write_csv` writes every `DateTime` column in one stated form,
  `TIMESTAMP_FORMAT` (`yyyy-mm-ddTHH:MM:SS.s`), the form CSV.jl 0.10 wrote
  by default and the products carry; CSV.jl 1.x, which DeepSpaceTelemetry
  2.6.0 brings into the script and test environments of the downstream
  packages, would otherwise write the instants without the decimal.
