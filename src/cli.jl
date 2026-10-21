# SPDX-License-Identifier: LGPL-3.0-or-later

# The pipeline's command-line tool from Julia: finding `fair`, running it, and
# installing a copy of the package's own, with a Python and a git of its own, for a
# Julia that has no virtual environment on its path.

# The Python the package's copy of the CLI runs on: the minor version the CLI's
# own workflows test on, above the floor of 3.10 the CLI and the registry share
const CLI_PYTHON = "3.12"

"""
    fair"arguments"

Run the pipeline's command-line tool `fair` with its arguments written as on
the command line, in the current directory, printing what it prints:
`fair"pull config.yaml"` is `fair pull config.yaml`. The text is
split as Julia's backticks split a command, so quotes group a word, and
`\$name` and `\$(expression)` interpolate, as in `fair"pull \$config"`. An exit
status other than 0 is a [`ReadWriteException`](@ref). The `fair` run is
found as [`rehearse`](@ref) finds it: the one [`set_cli!`](@ref) recorded,
else the one on the path, else the copy [`install_cli`](@ref) made. A command
that asks questions, as `fair init` does without `--ci`, needs a terminal.
"""
macro fair_str(text)
    command = Expr(:macrocall, GlobalRef(Base, Symbol("@cmd")), __source__,
                   text)
    return :(_fair($(esc(command)).exec...))
end

# Run `fair` with these arguments - `cli` naming the one to run, else the one
# found - in the folder `dir` if one is given, and throw on an exit status
# other than 0
function _fair(arguments::AbstractString...;
               cli::Union{Nothing, AbstractString, Cmd} = nothing,
               dir::Union{Nothing, AbstractString} = nothing)
    command = _withenvironment(`$(_faircommand(cli)) $arguments`)
    isnothing(dir) || (command = Cmd(command; dir = String(dir)))
    process = run(ignorestatus(command))
    success(process) ||
        throw(ReadWriteException("`fair $(join(arguments, " "))` failed with exit status $(process.exitcode)"))
    return nothing
end

"""
    set_cli!(path)
    set_cli!(nothing)

Record `path` as the `fair` this package runs - by [`rehearse`](@ref) and
[`@fair_str`](@ref), before any `fair` on the path or the copy
[`install_cli`](@ref) made - after checking that it runs. The record is a
preference in the `LocalPreferences.toml` of the first environment on the
load path that has DataPipeline: the active one where DataPipeline is among
its dependencies, else the one it is loaded from, such as the default
environment. It holds for every later session that takes DataPipeline from
that environment. `nothing` removes it. Return the path recorded.
"""
function set_cli!(path::AbstractString)
    executable = abspath(path)
    isfile(executable) ||
        throw(ArgumentError("no file at $executable to record as fair"))
    try
        read(_withenvironment(`$executable --version`), String)
    catch
        throw(ArgumentError("$executable does not run as fair: `--version` failed (the CLI needs git on the path)"))
    end
    # Into the environment that has the package, rather than the active one as
    # the macro does: a project that does not name the package would be given
    # it in `[extras]`, its Project.toml rewritten
    Preferences.set_preferences!(@__MODULE__, "cli" => executable,
                                 active_project_only = false, force = true)
    return executable
end
function set_cli!(::Nothing)
    Preferences.delete_preferences!(@__MODULE__, "cli",
                                    active_project_only = false, force = true)
    return nothing
end

"""
    install_cli(; version = nothing, python = nothing)

Install the package's own copy of `fair`, or bring it up to date, and return
the path of its executable. The copy lives in a scratch space of the
package's, with a Python and a git of its own that MicroMamba fetches from
conda-forge, so it needs no Python, no git and no virtual environment on the
machine, and [`rehearse`](@ref) and [`@fair_str`](@ref) use it when no `fair`
is on the path, running it with its own programs on the path.
`fair-cli` is installed from PyPI at its newest version, or at `version`; run
again, the call brings the copy up to date, printing its version before and
after. The Python is $CLI_PYTHON unless `python` names another minor version;
a change rebuilds the environment, as does an environment whose Python no
longer runs. A registry installed through this copy has an environment of its
own built with the copy's interpreter, so after such a rebuild it must be
installed again: `fair registry stop`, then `fair registry install --force`,
which a CLI may refuse while the registry runs. Needs the network.
"""
function install_cli(;
                     version::Union{Nothing, VersionNumber, AbstractString} = nothing,
                     python::Union{Nothing, AbstractString} = nothing)
    folder = _clifolder()
    wanted = isnothing(python) ? CLI_PYTHON : String(python)
    present = _clipythonversion(folder)
    if present != wanted
        if !isnothing(present)
            println("rebuilding the copy's environment with Python ", wanted,
                    " in place of ", present,
                    ": a registry installed through this copy must be installed again, ",
                    "with `fair registry stop` then `fair registry install --force`")
        elseif !isempty(readdir(folder))
            println("the copy's environment at ", folder,
                    " no longer runs: rebuilding it")
        end
        rm(folder, recursive = true, force = true)
        run(MicroMamba.cmd(`create --yes --quiet --prefix $folder python=$wanted pip git --channel conda-forge --override-channels`))
    end
    # A copy made before git came with it gets it
    isfile(_cligit(folder)) ||
        run(MicroMamba.cmd(`install --yes --quiet --prefix $folder git --channel conda-forge --override-channels`))
    before = _cliversion()
    specification = isnothing(version) ? "fair-cli" : "fair-cli==$version"
    run(`$(_clipython(folder)) -m pip install --quiet --upgrade $specification`)
    after = _cliversion()
    executable = _installedcli()
    isnothing(executable) &&
        throw(ReadWriteException("pip installed fair-cli, but there is no executable at $(_cliexecutable(folder))"))
    if isnothing(before)
        println("installed ", after, " at ", executable)
    elseif before == after
        println(after, " is up to date, at ", executable)
    else
        println("updated ", before, " to ", after, " at ", executable)
    end
    return executable
end

"""
    install_cli!(; version = nothing, python = nothing)

[`install_cli`](@ref), passing it `version` and `python`, then
[`set_cli!`](@ref) on the copy, whether it was installed by this call or
before: so that the copy is the `fair` this package runs, whatever is on the
path. Return the executable's path.
"""
function install_cli!(;
                      version::Union{Nothing, VersionNumber, AbstractString} = nothing,
                      python::Union{Nothing, AbstractString} = nothing)
    return set_cli!(install_cli(; version, python))
end

# The command that runs `fair`: the one given, as a path or a command; else
# the one the preference records, else the `fair` on the path, else the copy
# this package installed
_faircommand(cli::Cmd) = cli
function _faircommand(cli::AbstractString)
    path = isfile(cli) ? abspath(cli) : Sys.which(cli)
    isnothing(path) &&
        throw(ArgumentError("no `fair` at $cli, nor on the path"))
    return Cmd([path])
end
function _faircommand(::Nothing)
    preferred = _preferredcli()
    if !isnothing(preferred)
        isfile(preferred) ||
            throw(ArgumentError("the preference names $preferred as fair, where there is no file: set_cli! records another, or nothing"))
        return Cmd([preferred])
    end
    path = Sys.which("fair")
    isnothing(path) && (path = _installedcli())
    isnothing(path) || return Cmd([path])
    return throw(ArgumentError(string("no `fair` found: none recorded by set_cli!, none on the path, and ",
                                      "none installed by this package - run DataPipeline.install_cli!() to ",
                                      "install one and record it, or set_cli! on one you have")))
end

# The `fair` the preference records, or `nothing`
_preferredcli() = @load_preference("cli", nothing)

# The folder this package keeps its own copy of the CLI in, a scratch space of
# its own; the executable and the interpreter in such a folder, laid out as
# conda lays an environment out; and the executable if one has been installed
_clifolder() = @get_scratch!("fair-cli")
function _cliexecutable(folder::AbstractString)
    return Sys.iswindows() ? joinpath(folder, "Scripts", "fair.exe") :
           joinpath(folder, "bin", "fair")
end
function _clipython(folder::AbstractString)
    return Sys.iswindows() ? joinpath(folder, "python.exe") :
           joinpath(folder, "bin", "python")
end
function _cligit(folder::AbstractString)
    return Sys.iswindows() ? joinpath(folder, "Library", "bin", "git.exe") :
           joinpath(folder, "bin", "git")
end

# The folders of the copy's own programs, git among them, as a path
function _clibindirs(folder::AbstractString)
    dirs = Sys.iswindows() ?
           [
        folder,
        joinpath(folder, "Scripts"),
        joinpath(folder, "Library", "bin")
    ] :
           [joinpath(folder, "bin")]
    return join(dirs, Sys.iswindows() ? ';' : ':')
end

# A command that runs the package's copy of fair, given its own programs on
# the path, since the CLI wants git there as it starts; any other command as
# it is
function _withenvironment(command::Cmd)
    folder = _clifolder()
    first(command.exec) == _cliexecutable(folder) || return command
    separator = Sys.iswindows() ? ';' : ':'
    return addenv(command,
                  "PATH" => string(_clibindirs(folder), separator,
                         get(ENV, "PATH", "")))
end
function _installedcli()
    executable = _cliexecutable(_clifolder())
    return isfile(executable) ? executable : nothing
end

# The Python minor version of the copy's interpreter, as "3.12", or `nothing`
# where there is no interpreter or it no longer runs
function _clipythonversion(folder::AbstractString)
    python = _clipython(folder)
    isfile(python) || return nothing
    try
        return strip(read(`$python -c "import sys; print('%d.%d' % sys.version_info[:2])"`,
                          String))
    catch
        return nothing
    end
end

# What the copy's `fair --version` says, or `nothing` with no copy
function _cliversion()
    executable = _installedcli()
    isnothing(executable) && return nothing
    return strip(read(_withenvironment(`$executable --version`), String))
end

# Run `fair` with these arguments, in the folder `dir` if one is given,
# keeping what it prints and what it writes as errors apart, with its exit
# status
function _capturefair(command::Cmd, arguments::AbstractString...;
                      dir::Union{Nothing, AbstractString} = nothing)
    line = ignorestatus(_withenvironment(`$command $arguments`))
    isnothing(dir) || (line = Cmd(line; dir = String(dir)))
    printed, errors = IOBuffer(), IOBuffer()
    process = run(pipeline(line, stdout = printed, stderr = errors))
    return (status = process.exitcode, printed = String(take!(printed)),
            errors = String(take!(errors)))
end

# The oldest `fair-cli` this package works with
const CLI_NEEDED = v"0.11.0"

# The error for a `fair` that lacks `what`, which `fair-cli` before
# `CLI_NEEDED` lacks, saying how to have one that does not
function _oldcli(command::Cmd, what::AbstractString)
    return ReadWriteException("the fair at $(first(command.exec)) has no $what, which DataPipeline needs: fair-cli $CLI_NEEDED or later - `DataPipeline.install_cli!()` installs the package's own copy and records it, or `pip install --upgrade fair-cli` upgrades yours")
end

# Hold the local registry while this process uses it: through the session that
# the run which launched this process names in `FDP_SESSION`, else through a
# session of the CLI's, owned by this process. With no `fair` to be found,
# nothing holds it. A `fair` with no session commands, told by its usage
# error, is refused, as is a refusal from one that has them - on another host,
# say
function _holdregistry(cli::Union{Nothing, AbstractString, Cmd} = nothing)
    haskey(ENV, "FDP_SESSION") && return RegistryHeldByRun()
    command = try
        _faircommand(cli)
    catch err
        err isa ArgumentError || rethrow()
        return nothing
    end
    opened = _capturefair(command, "registry", "session", "open", "--pid",
                          string(getpid()), "--json")
    if opened.status != 0
        opened.status == 2 &&
            occursin("No such command 'session'", opened.errors) &&
            throw(_oldcli(command, "session commands"))
        throw(ReadWriteException("`fair registry session open` failed with exit status $(opened.status): $(strip(opened.errors))"))
    end
    reply = try
        JSON.parse(opened.printed)
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
    (reply isa AbstractDict &&
     all(haskey(reply, key)
         for key in ("session", "registry_url", "token_file"))) ||
        throw(ReadWriteException("`fair registry session open` printed no session: $(strip(opened.printed))"))
    _closeatexit()
    return RegistryHeldBySession(string(reply["session"]), command,
                                 string(reply["registry_url"]),
                                 string(reply["token_file"]))
end

"""
    registry_session(f; remote = nothing)

Call `f` with the [`RegistryEndpoint`](@ref) of the local registry, held up
for as long as `f` runs through a session of the FAIR CLI's, which this
process owns and closes when `f` returns or throws, and return what `f`
returns. The endpoint is the registry the session names, with the token in the
file it names. A session starts the registry where nothing holds it, and the
last to close stops one a session started; a registry started by `fair
registry start` runs until `fair registry stop`.

Each function that reads or writes a registry outside a run - [`identify`](@ref),
[`provenance`](@ref), [`downstream`](@ref), [`crate`](@ref),
[`register_release!`](@ref), [`raise_issue!`](@ref) outside a run - holds a
session for the call when given no endpoint, and takes this endpoint first to
share one:

```julia
DataPipeline.registry_session() do registry
    DataPipeline.identify(registry, "figures/summary.pdf")
    DataPipeline.provenance(registry, "figures/summary.pdf")
end
```

With `remote`, the name of a remote in the project's CLI configuration, `f` is
given that remote's endpoint instead, holding nothing. Under `fair run`, whose
own session holds the registry, nothing is opened, and `f` is given the
endpoint the CLI's configuration names.
"""
function registry_session(f::Function;
                          remote::Union{Nothing, AbstractString} = nothing)
    isnothing(remote) || return f(RegistryEndpoint(remote = remote))
    hold = _holdregistry()
    try
        return f(_heldendpoint(hold))
    finally
        hold isa RegistryHeldBySession && _releaseregistry(hold)
    end
end

# The endpoint of the local registry as what holds it names it: a session's
# address and the token in its file; otherwise the CLI's configuration's
function _heldendpoint(hold::RegistryHeldBySession)
    return RegistryEndpoint(hold.registry_url,
                            token = _tokenfromfile(Dict("token" =>
                                                            hold.token_file)))
end
_heldendpoint(::Union{Nothing, AbstractRegistryHold}) = RegistryEndpoint()

# Release what held the local registry for a rehearsal: a session of the
# CLI's is closed, which stops a registry it started where it was the last,
# and a failure is warned of, since the CLI treats the session of a process
# that has gone as closed
_releaseregistry(::Nothing) = nothing
_releaseregistry(::RegistryHeldByRun) = nothing
function _releaseregistry(hold::RegistryHeldBySession)
    closed = try
        _capturefair(hold.cli, "registry", "session", "close", hold.id)
    catch err
        err isa Base.IOError || rethrow()
        (status = nothing, printed = "", errors = sprint(showerror, err))
    end
    closed.status == 0 ||
        @warn "`fair registry session close $(hold.id)` failed: $(strip(closed.errors))"
    return nothing
end

# Whether a session still held when Julia exits is closed then, arranged once
const CLOSE_AT_EXIT = Ref(false)
function _closeatexit()
    CLOSE_AT_EXIT[] && return nothing
    atexit() do
        session = SESSION[]
        if !isnothing(session) && session.hold isa RegistryHeldBySession
            _releaseregistry(session.hold)
        end
    end
    CLOSE_AT_EXIT[] = true
    return nothing
end
