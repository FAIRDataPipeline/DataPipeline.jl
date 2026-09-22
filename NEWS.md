# NEWS

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
