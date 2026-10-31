# API reference

```@index
Pages = ["api.md"]
```

## Public interface

```@autodocs
Modules = [StreamingInference]
Private = false
Filter = t -> !(t in (
    StreamingInference.sidecar_path,
    StreamingInference.gapped_product,
    StreamingInference.run_channels,
    StreamingInference.load_threshold,
    StreamingInference.block_rows,
    StreamingInference.block_metrics,
    StreamingInference.metrics_dict,
    StreamingInference.print_block_summary,
    StreamingInference.fixed,
    StreamingInference.credited_span_label,
    StreamingInference.credited_span_times,
    StreamingInference.config_argument,
    StreamingInference.with_file_log,
))
```

## Stage helpers for method packages

The pieces of a training, calibration or inference stage that every
method package needs alike: the sidecar of a CSV product
([`sidecar_path`](@ref)), the window geometry and the feature map a
feature table was made with ([`feature_geometry`](@ref), with the
`fallback` section of a stage that only scores it, and
[`FeatureMap`](@ref) of a features path), the channel set, threshold and
split of a fitted run, the metrics of a scored block and their console
table, the credited spans of an event table for the figures, and the
configuration argument and file log of a script.

```@docs
sidecar_path
gapped_product
run_channels
load_threshold
block_rows
block_metrics
metrics_dict
print_block_summary
fixed
StreamingInference.credited_span_label
StreamingInference.credited_span_times
config_argument
with_file_log
```

## Internals

Helpers of the replay, the alert tables, the configuration and the
figures that are not exported, documented for those who extend the
package.

```@autodocs
Modules = [StreamingInference]
Public = false
```
