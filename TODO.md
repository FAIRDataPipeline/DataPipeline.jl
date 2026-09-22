# TODO

Outstanding work on DataPipeline.jl, as of v0.54.0 (unreleased, 2026-09-22). Each entry stands on
its own; the bracketed tags match the fuller discussion in the maintainer's planning notes. Delete
an entry when it is done, so that only outstanding work remains.

Sections are ordered by priority, and entries within them likewise.

## Decisions needed before the work can continue

- **When to release 0.54.0.** [DP3] It is what lets EcoSISTEM's `[compat]` move and its
  DataPipeline extension install at all. Nothing left in the parity work would force another
  breaking release.

## Parity with pyDataPipeline, remaining

- **`${{RUN_ID}}` elsewhere.** [DP4] Julia and the CLI now follow the documented `${{RUN_ID}}`
  (the CLI change is unstaged in `FAIR-CLI`). pyDataPipeline substitutes the single-brace
  `${RUN_ID}` and should move to the documented form; the CLI has no test for the exemption.

- **Wildcard reads elsewhere.** [DP5] Julia's `link_read!` on a pattern and `link_read_files!`
  are done (a `*` matches one name segment, anchored). Python's unmerged branch and R match by
  substring and Python names its links at random; the CI matrix runs Windows, where the
  directory form needs symlink permission and has not been tried.

## What Africa_plants will need beyond Python's shape (input to the case-study breakdown)

- **Many outputs per run.** [DP6] A full Africa cycle writes dozens of files per stage and
  replicate; the config names each `write:` entry in advance and each needs its own `link_write!`.
  Wants write-wildcards or a "register this directory" facility.
- **Very large outputs.** [DP7] `finalise` SHA-1s every output and `fair push` copies it; the
  end state is 10 GB. Decide whether the file or its metadata gets provenance.
- **MPI.** [DP8] Every rank runs the same script, so every rank would open a code run and try to
  register every output. The API has no "root rank only" notion; EcoSISTEM's own provenance
  writer already gathers under MPI.
- **Two provenance systems.** [DP9] EcoSISTEM's `InputRecord`s and Africa_plants' sidecars
  record what the registry records. Decide whether they become registry entries or the registry
  points at them. Then EcoSISTEM's compat bump, its pipeline example re-run and its docs page
  un-warned, all in that repository.

## Released API that is stubbed, off-spec or unverified

- **`read_table` and `write_table` are exported stubs** returning `nothing`. [DP10] Implement to
  the specification's `<component>/table` layout (an unused `read_h5_table` already knows it) or
  deprecate.
- **The HDF5 and TOML layouts differ from the specification and from R.** [DP11] `write_array`
  puts the dataset at `<component>` rather than `<component>/array`; `write_distribution` nests
  the parameters. Julia and R cannot exchange arrays or distributions until this is settled, and
  fixing the writers changes existing Julia-written files.
- **`api_audit.jl` is unexported and unverified** since a registry schema change. [DP12] Keep and
  test, or remove.
- **Nothing follows registry pagination**, and lookups assert exactly one match. [DP13] Past 100
  matching rows results silently degrade; the same in every language. `_postentry` also
  get-or-creates by every field, so two identical issues on the same components collapse.
- **The token comes only from `FDP_LOCAL_TOKEN`**, else the literal `fake_token`. [DP14] R also
  reads `~/.fair/registry/token`.
- **`initialise` cannot parse a hyphenated host or an SSH remote** as the repository root. [DP15]
  Measured: `gitlab-ext.example.org` and `git@github.com:a/b` both throw. Parse the URL properly.

## Package structure and dependencies

- **The SEIRS model, Plots and the test helpers live inside the package.** [DP16] Move the model
  to `examples/fdp` and the helpers to `test/`, so Plots is no longer a dependency of a registry
  client.
- **Unused dependencies**: SQLite, PrettyTables, UnicodePlots, FTPClient, NetCDF (on `main`),
  AxisArrays. [DP17] Verify by the examples and docs build, not by grep, before removing any.
- **Dead code and leftovers**: `_readdataproduct_from_file`, `read_h5_table`, `_checkexists`;
  `db/*.sql`, `docs/validation/`; `examples/fdp/main.jl` and its hand-written working configs,
  `other_sample_configs/`, the R scripts, `software-checklist.md`. [DP18] Decide what each is for.
- **Three unmerged branches**: `origin/rr/netcdf`, `origin/updated-deps`, `origin/practice`.
  [DP19] Decide the fate of each; NetCDF is out of scope for now.

## CI, docs and tooling

- **Every workflow installs the registry from its latest tag, which cannot install.** [DP20]
  Red until the registry is released; nothing to do here but know it.
- **Old action majors and a duplicated nightly workflow.** [DP21]
- **`docs/src/index.md` still describes a COVID-specific pipeline**, and the website's Julia
  page (another repository) calls the package by its old name and unregistered. [DP22]
- **Windows**: the registry's Windows scripts lack the port-specific stop; `link_read!`'s
  directory of symlinks needs a permission an ordinary user may lack. [DP23]
