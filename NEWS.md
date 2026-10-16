# NEWS

- v0.55.0
  - Breaking changes:
    - `initialise()` with no arguments reads the job folder `fair run` names in
      `FDP_CONFIG_DIR`, or the one `rehearse` prepared; it no longer falls back
      to `./config.yaml`.
    - A file written with the bytes of its data product's highest version makes
      no new version and is no output of the run: at `finalise` it moves from
      `handle.outputs` to `handle.unchanged`.
    - A source is one file: a second file under one identifier, title and
      release version is refused, at the call or at `finalise`.
    - Registering a source needs `data-registry` v1.4.0 or later.
    - `AncestorCommits()`, `CheckedOutCommit()` and `AllCommits()` made with no
      `repo` outside a git repository are an `ArgumentError`, since a selection
      holds its repository.
    - `initialise()` registers a commit's code repository as one object, kept
      where the registry holds one, and gives a new one the repository's own
      authors, from `codemeta.json`, `.zenodo.json`, `CITATION.cff` or its
      project file, rather than the runner; its licence and keywords too.
    - `registry_audit`, `registry_audit_recursive` and `record_issues!` are
      removed: written for the registry's 2021 schema, they could not run
      against any registry since. `provenance` and `downstream` are what they
      were for.
  - `DataPipeline.rehearse(path)` runs a script through the pipeline without
    recording it: `fair run --ci --dirty` prepares the job for a user config
    (a job folder, or its working config, may be given instead), the script
    then runs unchanged in the session, and `finalise` collects the outputs in
    a folder, registering nothing. `DataPipeline.discard` ends a rehearsal
    without its outputs; a second `rehearse` meanwhile is an error unless
    `restart = true` discards the first.
  - `initialise()` opens the run that `fair run` or `rehearse` prepared, once:
    a second call while it is open, or after it has ended, is an error.
  - `DataPipeline.fair"pull config.yaml"` runs the CLI from Julia, its
    arguments written as on the command line: the `fair` that `set_cli!`
    recorded, else the one on the path, else the copy `install_cli` made.
  - `DataPipeline.set_cli!(path)` records the `fair` to use, as a preference
    of the active environment that holds across sessions.
  - `DataPipeline.install_cli()` installs the package's own copy of `fair`, or
    brings it up to date, in a scratch space, with a Python and a git that
    MicroMamba fetches: for a Julia with no virtual environment on its path, and to set
    the registry up from Julia with `DataPipeline.fair"registry install"`.
    `install_cli!` records the copy as the `fair` to use as well.
  - `finalise()` returns the folder the outputs are under: the data store's
    root, or a rehearsal's folder.
  - `initialise()` outside `fair run` throws a `ConfigFileException` saying
    what sets a run up, rather than a `SystemError` or `KeyError`.
  - `RegistryEndpoint(; remote)` reads the registry's token from the file the
    CLI's configuration names beside its address, when none is given and the
    file exists: the token the CLI holds for that registry, sent to it alone.
  - `DataRegistryHandle` takes a type parameter, the run's mode, `RecordedRun`
    or `Rehearsal`; its registry URL fields are `nothing` in a rehearsal.
  - New dependencies: MicroMamba, Preferences and Scratch. Every standard
    library has a compat entry.
  - `link_write!` takes a `path`, to register a file that exists already: it is
    hard-linked into the data store, or copied. `link_read!` takes a `path`, and
    `force`, to make a registered file available there. `DataPipeline.canread`
    and `DataPipeline.canwrite` say whether the working config allows a call.
  - An output whose bytes are those of the highest version of its data product
    is no longer registered again: no version is made, the file written is
    removed, and it is not an output of the code run.
  - `write_array` writes HDF5 files that record no times, so the same arrays
    give the same file.
  - `link_write!` takes a file's source - `doi` or `bibtex`, with `title`,
    `primary`, `description`, `original_store`, `licence` (or `license`),
    `release_date` and `release_version` - and `finalise` registers it, the
    source's authors being the file's. A source is one file.
  - `register_citations!` reads BibTeX citations for `bibtex =`. A `doi` with
    none is looked up as DataCite's record, or CSL's, which gives what it has of
    the title, description, licence, date, version and authors' ORCIDs.
  - `register_authors!` registers authors with their ORCIDs or ROR ids, from
    TOML files or `name => identifier` pairs, for citations that name them.
  - A licence is an identifier in the SPDX licence list, checked against a copy
    the package keeps, or a URL.
  - `link_register!` registers something from outside the pipeline, with its
    source, as an input of the code run: a deposit with no file, or a file.
  - Registering a source needs `data-registry` v1.4.0 or later, which is checked.
    Wildcard writes need `fair-cli` 0.10.0 or later, a pattern read of a family
    written more than once 0.10.1, and reading a data product pulled from a
    remote, or pushing or pulling a deposit with no file, 0.10.2.
  - New dependencies: BibParser and BibInternal.
  - The abstract supertypes `AbstractIssueTarget` and `AbstractCommitSelection`
    are no longer `public`: they annotate arguments and are not for extending.
  - `DataPipeline.provenance(x)` traces where a data product came from - `x` a
    file or `namespace:name@version` - as a `Trace`, printed as a tree: each
    run at its commit, what it read, each input's source, issues and the
    version that supersedes it, back to the data registered from elsewhere.
  - `DataPipeline.downstream(x)` traces the other way, to everything made from
    a data product, from the runs of selected commits, or from everything an
    issue is raised on with `issue = `: what must be made again.
  - `DataPipeline.crate(paths...)` fetches the registry's RO-Crate for the
    files, folders and data products named, as its metadata or saved as a
    zip with `to = "paper.zip"`.
  - `identify` of a file also reports the issues raised on anything behind it,
    each with the run it reaches the file through, and with `superseded = true`
    the inputs behind it that a newer version of has been registered since.
  - A commit selection holds its repository, `repo` - a clone's top-level
    folder or its remote's URL, by default the open run's clone, else the
    repository holding the current directory - and is what `identify` and
    `downstream` take: `identify(AncestorCommits())`. The folder by position is
    deprecated.
  - `NamedCommit("v1.0")` selects a commit by tag, branch, hash or registered
    release's version; `AncestorCommits(of = "v1.0", including = false)` the
    commits before it.
  - `raise_issue!(target, description)` outside a run, with a registry or the
    CLI's, registers the issue at once and returns its URL, for an
    `ExistingDataProduct` or a commit selection: so
    `raise_issue!(AncestorCommits(of = "v1.2", including = false), "...")`
    raises an issue on the code before `v1.2`.
  - A registered data product is named `namespace:name@version` everywhere, as
    the CLI names one, with `namespace:name` for its newest version:
    `link_register!` takes the form in place of its `namespace` and `version`
    keywords, `ExistingDataProduct` takes it (the three-part constructor is
    deprecated), `raise_issue` takes it bare, and `identify` prints it.
  - Every call that changes what a run registers ends in `!`: `raise_issue!`,
    `read_array!`, `read_table!`, `read_estimate!`, `read_distribution!`,
    `write_array!`, `write_table!`, `write_estimate!` and `write_distribution!`,
    the old names kept as deprecations.
  - `raise_issue!` warns at `finalise` when the data product's bytes are
    registered as other versions of it too, and with `all_versions = true`
    raises the issue on every such version. A repeated `read_estimate!` or
    `read_distribution!` no longer looks its input up afresh.
  - `supersede = true` on `link_write!`, `link_register!` and the component
    writers raises an issue on the version a new version supersedes, at
    severity 0, so that what was made from the old version reports it; where
    there is nothing to supersede an info message says so.
  - Names are held to the pipeline's convention wherever the package registers
    one: a namespace of ASCII letters, digits, `_` and `-`, a component name of
    such parts joined by `/`, a data product name the same with `.` allowed
    inside a part; any other is an `ArgumentError`.
- v0.54.1
  - `link_write!`, and the component writers, accept a data product name that a
    wildcard `write:` entry of the working config stands for, registering the
    name given rather than the pattern. A name the patterns of several entries
    match is an error.
  - `DataPipeline.identify(registry_or_handle, path)` asks a registry what it
    knows about a file on disk, by the hash of its contents: what data products
    it is registered as, where the registry expects to find it, whether a newer
    version of any of them exists, and any issues raised against it. It returns
    a `FileIdentification`, which prints as a report.
  - `identify` also takes a git repository's top-level folder: the runs made
    from its commits, their outputs and issues (`commits =` chooses which, and
    `dirty = true` adds runs with uncommitted changes). With only a path it asks
    the CLI's local registry or a named `remote`, as `RegistryEndpoint()` does.
  - A run from a repository with uncommitted changes (`fair run --dirty` records
    `<commit>-dirty`) warns, and raises an issue against the repository.
  - `raise_issue`'s default severity is the registry's own default, 1, not 0.
  - An issue raised against several targets registers with `data-registry`
    v1.3.0, which refused the lookup `finalise` made (HTTP 400); and an issue
    is no longer attached to an identical one already raised against other
    targets instead of its own.
  - Reading a registry needs no token, so `identify` works outside `fair run`:
    `RegistryEndpoint(url; token)` carries its own token, sent to that registry
    only, and `DataPipeline.initialise(...; token)` takes it from
    `FDP_LOCAL_TOKEN` by default. The `fake_token` stand-in is gone; a write
    without a token fails with a `ReadWriteException` saying so.
  - An output can be registered when the registry holds more than one file type
    for its extension, which it permits; that used to fail with an assertion.
  - A registry lookup matching several entries reports the table, the query and
    the count instead of asserting.
- v0.54.0
  - The registry is taken from `run_metadata.local_data_registry_url` in the
    working config (default `http://127.0.0.1:8000/api/`), so a registry on
    another host or port works; `run_metadata.api_version` is sent with every
    request.
  - `finalise` appends the code run's uuid to `coderuns.txt` beside the working
    config, so `fair add` and `fair push` can stage Julia code runs.
  - `raise_issue` has a new signature: `raise_issue(handle, target, description;
    severity = 0)`, where a target is a data product name, `WorkingConfig()`,
    `SubmissionScript()`, `CodeRepository()`, `ConfigDataProduct(...)` or
    `ExistingDataProduct(...)`, or a vector of them for one issue on several
    things. Issues are queued and registered at `finalise`. The old
    `raise_issue(handle, url, description, severity)` is gone; it could not run.
  - Don't allow last argument on read_*() to be optional (they were broken anyway).
  - Output files get a temporary `dat-<random>` name until `finalise`, in every
    write function.
  - `initialise` and `finalise` are no longer exported but `public`: call them
    as `DataPipeline.initialise()` and `DataPipeline.finalise(handle)`, since a
    model is likely to have functions of those names itself. The issue-target
    types, `DataRegistryHandle`, `RegistryEndpoint` and the two exceptions are
    `public` too.
  - `DataRegistryHandle` prints a summary rather than its whole contents.
  - `remote_repo` may be any URL, or an scp-style SSH remote, not only a host
    of lower-case letters.
  - An output whose bytes are already in the data store is deleted and its
    data product pointed at the existing file, as the other APIs do; every
    data product gets an object of its own, shared by its components.
  - Julia 1.11 or later is required.
  - `${{RUN_ID}}` in a `write:` data product name is replaced by the code run's
    uuid at `finalise`, as the pipeline documentation describes (the CLI leaves
    it for the API to fill in).
  - `link_read!` given a pattern (a name with `*`s, each matching one segment)
    returns a temporary directory of links to every matching `read:` data
    product, and the new `link_read_files!` returns their paths; each match is
    recorded as an input.
- v0.53.2
- v0.53.1
- v0.53.0
  - Windows and workflow fixes
- v0.52.0
  - Code re-write
- v0.51.0
  - Register new name with General
