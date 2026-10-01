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
