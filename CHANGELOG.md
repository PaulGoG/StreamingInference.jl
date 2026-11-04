# Changelog

All notable changes to this package are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.1] — 2026-11-04

### Changed
- The producer extension reads a DeepSpaceTelemetry run through the reader's
  adapter alone and loads with DeepSpaceTelemetryReader 3.2: `batch_records`
  resolves each named batch with `RunAdapter.batch_record`, under the record
  rule of `list_batches` (the content epoch the batch carries is checked
  against its payload rows); `read_batch` reads with `delivered = true`, so
  a lost, pruned or absent batch is an `ArgumentError` of the adapter; and
  `run_descriptor` is `RunAdapter.run_descriptor`, which checks the schema of
  `descriptor.toml`. No path into the run directory is built.
- The test environment pins DeepSpaceTelemetry 3.2.0 (3.1.1 stamps installed
  copies clean again, 3.1.0 having left the tracked `data/` root out of its
  identity hash); the suite asserts `git_dirty == false` once more.

## [0.2.0] — 2026-10-31

### Changed
- Breaking: the producer extension loads with DeepSpaceTelemetryReader 3.1, the
  reader package of DeepSpaceTelemetry (`Pkg.add(url = ..., subdir =
  "reader")`, or carried by DeepSpaceTelemetry itself), in place of
  DeepSpaceTelemetry 2.6: a consumer that only replays runs no longer loads
  the figure stack and the HDF5 export of the producer. `open_telemetry_run`
  opens the runs the adapter opens, those of producers from 2.6.0, whatever
  `producer_compat` (default now `"2.6"`) asks below that; the branches for
  earlier producers are gone with them: payload rows reconstructed from the
  batch index, holes derived from the event logs, the refusal of
  external-payload runs of 2.0.1 with a generation gap or an emitter
  restart. The run descriptor of a 3.x producer carries
  `schema = "deepspacetelemetry-run/2"`.
- The test environment carries `[compat]` entries and pins
  DeepSpaceTelemetry 3.1.0; the suite runs the producer under a run root of
  its own (`run_mission(...; data_root)`) instead of swapping the
  producer's default.
- Breaking: `extract_features(x, sample_rate; low_band, high_band, ...)`
  takes `sample_rate` as a required positional argument and the analysis
  bands as required keywords; `window_features` requires `band_edges`, and
  `FeatureMap` requires `low_band`, `high_band` and `band_edges`. The
  defaults of 0.2 Hz and of the millihertz bands are gone.
- Breaking: `write_toml(...; tag = true)` throws an `ArgumentError` for a
  key of the data named `hardware`, `git`, `layers`, `environment` or
  `written_at`, which the provenance sections used to replace silently.
- Breaking: `WindowScheduler` is immutable.
- Breaking: `animate_mission_replay` requires the `window` column of the
  replay table and counts an alarm episode over windows consecutive in
  window index, as `alert_latency_table` does: a window missing from the
  table ends an episode.
- `feature_geometry(features_path, config; fallback = "preprocessing")`
  reads the geometry of a table without sidecar from the section
  `fallback`.
- `threshold_sweep` and `select_threshold` take `windows`, the record
  window indices of a block with gaps, and pass them to `event_metrics`.
- `process_event!` warns once per name when an `ingested`, `lost` or
  `pruned` event names a batch the run does not list; such an event used
  to be skipped without notice.
- `save_animation(...; px_per_unit = ANIMATION_PX_PER_UNIT)` records the
  raster scale it is given; it recorded the default whatever the renderer
  used.
- The error of `alert_latency_table` for label spans without signal onsets
  no longer names stages of other packages.
- Docstrings and the manual: the availability latency and the reveal
  order of the replay figures follow `scored_at`; the first argument of
  `figure_score_distribution` is `scores`; the `GapEvent` causes are listed
  alike in the docstring and the manual; `RunGeometry` shows its
  constructor and `animate_mission_replay` the default `epoch`;
  `AbstractWindowEstimator` is documented as a reserved supertype, the
  replay driving scalar scorers; the README lists the producer vocabulary
  of `RunGeometry` and `ArrivalEvent` and the generic exported names among
  the known limitations. Wording of docstrings, comments, the README, the
  manual and the 0.1.0 entries below revised.
- Internal: `finite_stretches`, the alert runs and the alarm episodes of
  the animation share `contiguous_runs`; the alert table and the figures
  share one conversion of instants to hours and days; the replay figures
  share their span shading and legend assembly; one path normalisation
  (`normdir`).
- `Project.toml` names the author without e-mail; Dependabot watches the
  `test/` and `docs/` environments; the formatting check pins
  JuliaFormatter 2.


### Added
- Stage helpers for method packages: `sidecar_path`, the sidecar reader
  `FeatureMap(features_path)`,
  `gapped_product`, `run_channels(model_dir; default)`, `load_threshold`
  (with the `validation_*` keys of older files read as `fit_*`),
  `block_rows`, `block_metrics(scores, labels, threshold, geometry;
  windows)`, `metrics_dict`, `fixed`, `print_block_summary(rows; io)`,
  `config_argument(default; args)`, which takes the first `.toml`
  argument wherever it stands among the options, and `with_file_log(f,
  path)`; LoggingExtras is a dependency.
- `credited_span_times(events, geometry; crediting)`, the mission-time
  intervals of the credited spans of an event table, one `fallback_span`
  before each event time without label spans; it and
  `credited_span_label` are public.
- `hours_between(a, b)` and `days_since(epoch, t)`, public, the intervals
  between instants in hours and days.

### Removed
- `window_lost`, an unused internal.

## [0.1.0] — 2026-10-15

### Added
- `threshold_sweep` and `select_threshold` take `tail_candidates`: that
  many candidate thresholds added to the upper tail of the score
  distribution, at quantiles `1 - ε` with `ε` log-spaced from the quantile
  step `1/(n_candidates - 1)` down to one window, so that on a block
  without signal the false-alarm rates between one episode and the coarse
  step become reachable; the default 0 keeps every existing sweep and
  fitted threshold unchanged.
- A confirmation tier of the alert table: `alert_latency_table(...;
  confirmation_persistence)` confirms an alert by the arrival that
  completes that many consecutive alarmed windows touching the credited
  span and counts the confirmations outside every span; the value must
  exceed the window overlap `window_overlap(windows)` (window length over
  step), so that a confirmed alert rests on alarms of windows sharing no
  sample. With the default 0 the table is unchanged.
- First release. The package holds the domain-general layer formerly
  inside MilliHertzQML.jl (3.0.0-DEV): the estimator interface and stateful
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
  by name as the channels of a matrix; `telemetry_run_columns` names the
  columns a run carries. The rows of a batch follow the
  payload row the producer stamps (2.1.0 and later), checked against its
  content epoch, and its content epoch for earlier producers. The
  adapter moved here from MilliHertzBase.jl.
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
- `[inference] block` (`inference_settings`) accepts any non-empty block
  name, not only `validation` and `test`: the run that is scored persists
  the split that names its blocks (a calibration run has `calibration` and
  `evaluation`), and the consumer checks the name against it
  (`check_block`).
- The README and the manual were rewritten for a first reader. Docstrings
  no longer refer to the other packages; the false-alarm episodes of
  `alert_latency_table` are those outside every credited span, as computed
  (the docstring said label span), and `read_batch` may return a matrix.
- `follow_run` polls the declared holes beside the arrival feed, resolves
  only the batches its fresh arrivals name (`batch_records`), polls again
  at once while the feeds deliver, and stops once the record is final
  (`record_final`) and both feeds are drained, so a live replay ends with
  the data.
- `ScheduledRecordRun` resolves a batch its schedule delivers after the
  run was wrapped, so that it serves a followed run.
- Replays of runs whose producer declares generation gaps change at the
  edges of those gaps: the declared rows are widened by the erosion, so
  the window whose conditioning stretch begins within `tdi_gap_dilation_sec`
  after a gap is no longer scored. Runs without declared holes replay
  unchanged.
- `write_csv` writes every `DateTime` column in one stated form,
  `TIMESTAMP_FORMAT` (`yyyy-mm-ddTHH:MM:SS.s`), the default of CSV.jl 0.10,
  under CSV.jl 0.10 and 1.x alike.
