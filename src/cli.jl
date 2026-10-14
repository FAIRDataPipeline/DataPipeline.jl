# SPDX-License-Identifier: LGPL-3.0-or-later

# The pipeline's command-line tool from Julia: finding `fair`, running it, and
# installing a copy of the package's own, with a Python of its own, for a
# Julia that has no virtual environment on its path.

# The Python the package's copy of the CLI runs on: the minor version the CLI's
# own workflows test on, above the floor of 3.10 the CLI and the registry share
const CLI_PYTHON = "3.12"

"""
    DataPipeline.fair"arguments"

Run the pipeline's command-line tool `fair` with its arguments written as on
the command line, in the current directory, printing what it prints:
`DataPipeline.fair"pull config.yaml"` is `fair pull config.yaml`. The text is
split as Julia's backticks split a command, so quotes group a word, and
`\$name` and `\$(expression)` interpolate, as in `fair"pull \$config"`. An exit
status other than 0 is a [`ReadWriteException`](@ref). The `fair` run is
found as [`rehearse`](@ref) finds it: on the path, else the copy
[`install_cli`](@ref) made, else the one `FDP_FAIR_CLI` names. A command that
asks questions, as `fair init` does without `--ci`, needs a terminal.
"""
macro fair_str(text)
    command = Expr(:macrocall, GlobalRef(Base, Symbol("@cmd")), __source__,
                   text)
    return :(_fair($(esc(command)).exec...))
end

# Run `fair` with these arguments - `cli` naming the one to run, else the one
# found - and throw on an exit status other than 0
function _fair(arguments::AbstractString...;
               cli::Union{Nothing, AbstractString, Cmd} = nothing)
    command = `$(_faircommand(cli)) $arguments`
    process = run(ignorestatus(command))
    success(process) ||
        throw(ReadWriteException("`fair $(join(arguments, " "))` failed with exit status $(process.exitcode)"))
    return nothing
end

"""
    install_cli(; version = nothing, python = nothing)

Install the package's own copy of `fair`, or bring it up to date, and return
the path of its executable. The copy lives in a scratch space of the
package's, with a Python of its own that MicroMamba fetches from conda-forge,
so it needs no Python on the machine and no virtual environment, and
[`rehearse`](@ref) and [`@fair_str`](@ref) use it when no `fair` is on the
path.
`fair-cli` is installed from PyPI at its newest version, or at `version`; run
again, the call brings the copy up to date, printing its version before and
after. The Python is $CLI_PYTHON unless `python` names another minor version;
a change rebuilds the environment, as does an environment whose Python no
longer runs. A registry installed through this copy has an environment of its
own built with the copy's interpreter, so after such a rebuild it must be
installed again, with `fair registry install --force`. Needs the network.
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
                    ": a registry installed through this copy must be installed again")
        elseif !isempty(readdir(folder))
            println("the copy's environment at ", folder,
                    " no longer runs: rebuilding it")
        end
        rm(folder, recursive = true, force = true)
        run(MicroMamba.cmd(`create --yes --quiet --prefix $folder python=$wanted pip --channel conda-forge --override-channels`))
    end
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

# The command that runs `fair`: the one given, as a path or a command; else
# the `fair` on the path, else the copy this package installed, else the
# executable `FDP_FAIR_CLI` names
_faircommand(cli::Cmd) = cli
function _faircommand(cli::AbstractString)
    path = isfile(cli) ? abspath(cli) : Sys.which(cli)
    isnothing(path) &&
        throw(ArgumentError("no `fair` at $cli, nor on the path"))
    return Cmd([path])
end
function _faircommand(::Nothing)
    path = Sys.which("fair")
    isnothing(path) && (path = _installedcli())
    isnothing(path) || return Cmd([path])
    if haskey(ENV, "FDP_FAIR_CLI")
        path = ENV["FDP_FAIR_CLI"]
        isfile(path) ||
            throw(ArgumentError("FDP_FAIR_CLI names $path, where there is no file"))
        return Cmd([path])
    end
    return throw(ArgumentError(string("no `fair` found: none on the path, none installed by this package, ",
                                      "and FDP_FAIR_CLI not set - run DataPipeline.install_cli() to install ",
                                      "one, give `cli =` the executable, or set FDP_FAIR_CLI to it")))
end

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
    return strip(read(`$executable --version`, String))
end
