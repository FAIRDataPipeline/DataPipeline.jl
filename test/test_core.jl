# SPDX-License-Identifier: LGPL-3.0-or-later

module TestCore

using Dates
using DataPipeline
using Test

registry = DataPipeline.RegistryEndpoint("http://localhost:8000/api/")

Test.@testset "RegistryEndpoint" begin
    @test registry.url == "http://localhost:8000/api/"
    @test registry.api_version == "1.0.0"
    # A missing trailing slash is added, and the version is kept
    other = DataPipeline.RegistryEndpoint("http://127.0.0.1:8002/api", "1.1.0")
    @test other.url == "http://127.0.0.1:8002/api/"
    @test other.api_version == "1.1.0"
    @test DataPipeline._headers(other)["Accept"] ==
          "application/json; version=1.1.0"

    # No token unless one is given, and then no Authorization header at all
    @test isnothing(registry.token)
    @test !haskey(DataPipeline._headers(registry), "Authorization")
    secret = DataPipeline._randomhash()
    keyed = DataPipeline.RegistryEndpoint("http://127.0.0.1:8002/api/",
                                          token = secret)
    @test keyed.api_version == DataPipeline.DEFAULT_API_VERSION
    @test DataPipeline._headers(keyed)["Authorization"] == "token $secret"

    # Printing shows the registry but never the token
    for text in (sprint(show, keyed), repr(MIME("text/plain"), keyed))
        @test occursin(keyed.url, text)
        @test !occursin(secret, text)
    end
    @test occursin("no token", sprint(show, registry))
end

Test.@testset "a registry that does not answer" begin
    # One at a loopback address is the local registry, which the error says
    # how to start; one anywhere else is not called local
    for url in ("http://127.0.0.1:8000/api/", "http://localhost:8000/api/",
        "http://[::1]:8000/api/")
        msg = DataPipeline._unreachable(DataPipeline.RegistryEndpoint(url)).msg
        @test startswith(msg, "cannot reach the local registry at $url: ")
        @test occursin("`fair registry start`", msg)
    end
    @test DataPipeline._unreachable(DataPipeline.RegistryEndpoint("https://data.example.org/api/")).msg ==
          "cannot reach the registry at https://data.example.org/api/"
    # What a read meets where nothing listens
    closed = DataPipeline.RegistryEndpoint("http://127.0.0.1:1/api/")
    err = @test_throws DataPipeline.ReadWriteException DataPipeline._getentry(closed,
                                                                              DataPipeline.URIs.URI(closed.url))
    @test occursin("`fair registry start`", err.value.msg)
end

Test.@testset "RegistryEndpoint() from the CLI's configuration" begin
    # A home and a project of our own, so that nothing depends on the
    # machine's configuration; `homedir()` reads USERPROFILE on Windows
    home = mktempdir()
    project = joinpath(home, "project")
    mkpath(joinpath(project, ".fair"))
    mkpath(joinpath(project, "sub", "dir"))
    withenv("HOME" => home, "USERPROFILE" => home) do
        # No global configuration: the CLI's default
        @test DataPipeline.RegistryEndpoint().url ==
              DataPipeline.DEFAULT_REGISTRY_URL

        mkpath(joinpath(home, ".fair", "cli"))
        DataPipeline.YAML.write_file(joinpath(home, ".fair", "cli",
                                              "cli-config.yaml"),
                                     Dict("registries" =>
                                              Dict("local" =>
                                                       Dict("uri" => "http://127.0.0.1:8123/api/"))))
        local_registry = DataPipeline.RegistryEndpoint()
        @test local_registry.url == "http://127.0.0.1:8123/api/"
        @test local_registry.api_version == DataPipeline.DEFAULT_API_VERSION
        @test isnothing(local_registry.token)        # no token file named
        @test DataPipeline.RegistryEndpoint(token = "secret").token == "secret"

        # The token is read from the file the entry names, stripped, when
        # the file exists and holds one; a token given wins
        token_file = joinpath(home, ".fair", "registry", "token")
        mkpath(dirname(token_file))
        DataPipeline.YAML.write_file(joinpath(home, ".fair", "cli",
                                              "cli-config.yaml"),
                                     Dict("registries" =>
                                              Dict("local" =>
                                                       Dict("uri" => "http://127.0.0.1:8123/api/",
                                                            "token" =>
                                                                token_file))))
        @test isnothing(DataPipeline.RegistryEndpoint().token)   # not yet written
        write(token_file, "\n")
        @test isnothing(DataPipeline.RegistryEndpoint().token)   # empty
        write(token_file, "localsecret\n")
        @test DataPipeline.RegistryEndpoint().token == "localsecret"
        @test DataPipeline.RegistryEndpoint(token = "secret").token == "secret"

        # A remote is looked up in the project's configuration, found by
        # walking up from the current directory, with a token file of its
        # own: the local registry's is never sent to it
        remote_token_file = joinpath(home, ".fair", "cli", "remotetoken.txt")
        write(remote_token_file, "remotesecret")
        DataPipeline.YAML.write_file(joinpath(project, ".fair",
                                              "cli-config.yaml"),
                                     Dict("registries" =>
                                              Dict("origin" =>
                                                       Dict("uri" => "https://example.org/api/",
                                                            "token" =>
                                                                remote_token_file),
                                                   "tokenless" =>
                                                       Dict("uri" => "https://example.net/api/"))))
        cd(joinpath(project, "sub", "dir")) do
            origin = DataPipeline.RegistryEndpoint(remote = "origin")
            @test origin.url == "https://example.org/api/"
            @test origin.token == "remotesecret"
            @test isnothing(DataPipeline.RegistryEndpoint(remote = "tokenless").token)
            err = try
                DataPipeline.RegistryEndpoint(remote = "elsewhere")
            catch e
                e
            end
            @test err isa DataPipeline.ConfigFileException
            @test occursin("origin", err.msg)          # names what there is
        end
        # The walk stops at the home directory, whose `.fair` is the global
        # configuration rather than a project's: a project-style file there
        # is not read
        DataPipeline.YAML.write_file(joinpath(home, ".fair", "cli-config.yaml"),
                                     Dict("registries" =>
                                              Dict("local" =>
                                                       Dict("uri" => "http://wrong/api/"))))
        cd(home) do
            @test_throws DataPipeline.ConfigFileException DataPipeline.RegistryEndpoint(remote = "local")
        end
    end
end

Test.@testset "writing needs a token" begin
    # Refused before any request is made, so no registry need be running
    @test_throws DataPipeline.ReadWriteException DataPipeline._postentry(registry,
                                                                         "namespace",
                                                                         Dict("name" => "never"))
    @test_throws DataPipeline.ReadWriteException DataPipeline._createentry(registry,
                                                                           "namespace",
                                                                           Dict("name" => "never"))
    err = try
        DataPipeline._postentry(registry, "namespace", Dict("name" => "never"))
    catch e
        e
    end
    @test occursin("FDP_LOCAL_TOKEN", err.msg)
end

Test.@testset "_convertquery()" begin
    # Test boolean
    test_boolean = DataPipeline._convertquery(registry, Dict("public" => true))
    @test test_boolean == "?public=true"

    # Test strings
    test_string = DataPipeline._convertquery(registry,
                                             Dict("name" => "string/1"))
    @test test_string == "?name=string%2F1"

    # Test integers
    @test DataPipeline._convertquery(registry, Dict("severity" => 3)) ==
          "?severity=3"

    # Test multiple key-value pairs
    test_string2 = DataPipeline._convertquery(registry,
                                              Dict("description" => "Short description",
                                                   "key" => "value"))
    # Dict iteration order is unspecified, so compare the pairs rather than the string
    @test startswith(test_string2, "?")
    @test Set(split(test_string2[2:end], "&")) ==
          Set(["key=value", "description=Short%20description"])

    # Test datetimes
    rt = Dates.now()
    rt = Dates.format(rt, "yyyy-mm-dd HH:MM:SS")
    test_date = DataPipeline._convertquery(registry, Dict("run_date" => rt))
    ans = replace(replace(rt, s":" => s"%3A"), s" " => s"%20")
    @test test_date == "?run_date=$ans"

    # Test URLs: only this registry's URLs become ids
    namespace_query = Dict("namespace" => "http://localhost:8000/api/namespace/19/")
    test_url = DataPipeline._convertquery(registry, namespace_query)
    @test test_url == "?namespace=19"
    other = DataPipeline.RegistryEndpoint("http://127.0.0.1:8002/api/")
    @test DataPipeline._convertquery(other, namespace_query) ==
          "?namespace=" *
          "http%3A%2F%2Flocalhost%3A8000%2Fapi%2Fnamespace%2F19%2F"
    @test DataPipeline._convertquery(other,
                                     Dict("namespace" => "http://127.0.0.1:8002/api/namespace/19/")) ==
          "?namespace=19"

    # Test URLs in array, with ids of more than one digit
    author_query = Dict("authors" => ["http://localhost:8000/api/author/10/",
                            "http://localhost:8000/api/author/211/"])
    test_url = DataPipeline._convertquery(registry, author_query)
    @test test_url == "?authors=10,211"
end

Test.@testset "_extractid()" begin
    @test DataPipeline._extractid("http://localhost:8000/api/author/1/") == "1"
    @test DataPipeline._extractid("http://localhost:8000/api/author/1234/") ==
          "1234"
    @test DataPipeline._extractid(["http://localhost:8000/api/author/10/",
                                      "http://localhost:8000/api/author/11/"]) ==
          ["10", "11"]
end

Test.@testset "_globregex()" begin
    g = DataPipeline._globregex
    # One * is one segment of a name: no /, and not empty
    @test occursin(g("era5/t2m/*"), "era5/t2m/1940-1949")
    @test !occursin(g("era5/t2m/*"), "era5/t2m/a/b")
    @test !occursin(g("era5/t2m/*"), "era5/t2m/")
    # Anchored at both ends
    @test !occursin(g("era5/t2m/*"), "archive/era5/t2m/1930-1939")
    @test !occursin(g("era5/t2m/*"), "era5/t2m/1940-1949/extra")
    # As many * as needed, anywhere
    @test occursin(g("era5/*/1940-*"), "era5/tp/1940-1949")
    @test !occursin(g("era5/*/1940-*"), "era5/tp/1950-1959")
    @test occursin(g("*"), "single")
    @test !occursin(g("*"), "two/segments")
    # Everything else is literal, regex metacharacters included
    @test occursin(g("chelsa/bio1.2/*"), "chelsa/bio1.2/x")
    @test !occursin(g("chelsa/bio1.2/*"), "chelsa/bio1x2/x")
    @test occursin(g("a+b(c)[d]{e}|f?^\$/*"), "a+b(c)[d]{e}|f?^\$/x")
    @test_throws ArgumentError g("era5/t2m")
    # A segment is anything a registered name can hold but /, whether or not
    # the naming convention allows it, and never the four characters the
    # registry refuses, so that a pattern does not match itself
    @test occursin(g("family/*"), "family/a b+c.d.")
    @test !occursin(g("family/*"), "family/*")
    for refused in ('[', ']', '?', '*')
        @test !occursin(g("family/*"), "family/a$(refused)b")
    end
end

Test.@testset "_repositorylocation()" begin
    loc = DataPipeline._repositorylocation
    @test loc("https://github.com/FAIRDataPipeline/DataPipeline.jl") ==
          (root = "https://github.com/",
           path = "FAIRDataPipeline/DataPipeline.jl")
    @test loc("https://github.com/FAIRDataPipeline/DataPipeline.jl.git") ==
          (root = "https://github.com/",
           path = "FAIRDataPipeline/DataPipeline.jl.git")
    # Hosts with digits, hyphens and ports
    @test loc("https://gitlab-ext.example.org/a/b") ==
          (root = "https://gitlab-ext.example.org/", path = "a/b")
    @test loc("http://git.host2.org:8080/a/b") ==
          (root = "http://git.host2.org:8080/", path = "a/b")
    @test loc("ssh://git@github.com/a/b.git") ==
          (root = "ssh://git@github.com/", path = "a/b.git")
    # scp-style SSH remotes are registered under the host's https root
    @test loc("git@github.com:a/b.git") ==
          (root = "https://github.com/", path = "a/b.git")
    @test_throws DataPipeline.ConfigFileException loc("not a remote")
end

Test.@testset "_getentries() follows pagination" begin
    # The registry of the run the tests were launched in
    launched = DataPipeline._workingconfig(DataPipeline.FDP_PATH_CONFIG())
    r = DataPipeline.RegistryEndpoint(launched["run_metadata"]["local_data_registry_url"],
                                      token = DataPipeline.FDP_LOCAL_TOKEN())
    # The registry pages at 100, so make more than one page of cheap rows.
    # Its namespace filter matches a name exactly, so the check is against the
    # whole table rather than a filtered subset
    tag = DataPipeline._randomhash()[1:8]
    names = Set("pagination/$tag/$i" for i in 1:101)
    for name in names
        DataPipeline._postentry(r, "namespace", Dict("name" => name))
    end
    page = DataPipeline._getentry(r,
                                  DataPipeline.URIs.URI(r.url * "namespace/"))
    @test page["count"] >= 101
    @test length(page["results"]) == 100     # a page holds 100
    @test !isnothing(page["next"])
    all = DataPipeline._getentries(r, "namespace", Dict())
    @test length(all) == page["count"]
    @test names ⊆ Set(entry["name"] for entry in all)
end

Test.@testset "_randomhash()" begin
    hashes = [DataPipeline._randomhash() for _ in 1:100]
    @test all(h -> length(h) == 40 && all(c -> c in "0123456789abcdef", h),
              hashes)
    @test length(unique(hashes)) == 100
end

Test.@testset "FDP_LOCAL_TOKEN()" begin
    # `fair run` sets the token; outside it there is none, and nothing stands
    # in for it
    @test length(DataPipeline.FDP_LOCAL_TOKEN()) == 40
    withenv("FDP_LOCAL_TOKEN" => nothing) do
        @test isnothing(DataPipeline.FDP_LOCAL_TOKEN())
    end
end

Test.@testset "a data product named namespace:name@version" begin
    parse = DataPipeline._parsedataproduct
    full = parse("PSU:SEIRS_model/parameters@v1.0.0")
    @test full == (namespace = "PSU", name = "SEIRS_model/parameters",
           version = "1.0.0")
    # The version with or without its v, and written in full; none, nothing
    @test parse("PSU:SEIRS_model/parameters@1.0.0") == full
    @test parse("PSU:SEIRS_model/parameters@1.0").version == "1.0.0"
    @test isnothing(parse("PSU:SEIRS_model/parameters").version)
    # The namespace given, else the default, else an error
    @test parse("x:a").namespace == "x"
    @test parse("a", default = "d") == (namespace = "d", name = "a",
           version = nothing)
    @test parse("a@2.0.0", default = "d").version == "2.0.0"
    @test parse("x:a", default = "d").namespace == "x"
    err = @test_throws ArgumentError parse("a")
    @test occursin("names no namespace", err.value.msg)
    # What the convention refuses: in the namespace, the name, the version
    for text in ("P SU:a", "p.su:a", "PSU/x:a")
        err = @test_throws ArgumentError parse(text)
        @test occursin("is not a namespace", err.value.msg)
    end
    for text in ("PSU:a b", "PSU:a:b", "PSU:a@b@1.0.0", "PSU:", "PSU:/a",
        "PSU:a//b", "PSU:a/", "PSU:.hidden", "PSU:a/.b", "PSU:a.", "PSU:a/b.",
        "PSU:.", "PSU:a/..", "PSU:a/../b")
        err = @test_throws ArgumentError parse(text)
        @test occursin("is not a data product name", err.value.msg)
    end
    # A period inside a part of a name, as a repository's name has one
    @test parse("FAIRDataPipeline:DataPipeline.jl@v0.55.0") ==
          (namespace = "FAIRDataPipeline", name = "DataPipeline.jl",
           version = "0.55.0")
    @test parse("PSU:a.b.c/d.e").name == "a.b.c/d.e"
    @test parse("PSU:a..b").name == "a..b"
    @test_throws ArgumentError DataPipeline._checkcomponent("a.b")
    @test_throws ArgumentError DataPipeline._checknamespace("a.b")
    err = @test_throws ArgumentError parse("PSU:a@061")
    @test occursin("`version`", err.value.msg)
    @test_throws ArgumentError parse("PSU:a@")

    # The name written back, and a name to be written may hold the run's id
    name = DataPipeline._dataproductname
    @test name("PSU", "SEIRS_model/parameters", "1.0.0") ==
          "PSU:SEIRS_model/parameters@v1.0.0"
    @test name("PSU", "SEIRS_model/parameters", v"1.0.0") ==
          "PSU:SEIRS_model/parameters@v1.0.0"
    @test name("PSU", "SEIRS_model/parameters") == "PSU:SEIRS_model/parameters"
    @test DataPipeline._checkdataproduct("out/\${{RUN_ID}}") ==
          "out/\${{RUN_ID}}"
    @test DataPipeline._checkdataproduct("out/\${{ RUN_ID }}/x") ==
          "out/\${{ RUN_ID }}/x"
    @test_throws ArgumentError DataPipeline._checkdataproduct("out/\${{ID}}")
    @test DataPipeline._checkcomponent("a/b-c_1") == "a/b-c_1"
    @test_throws ArgumentError DataPipeline._checkcomponent("a b")
    @test_throws ArgumentError DataPipeline._checknamespace("")

    # The issue target, from the string, with the three-part form kept as a
    # deprecation that makes the same thing
    target = DataPipeline.ExistingDataProduct("PSU:SEIRS_model/parameters@v1.0.0",
                                              component = "c")
    @test target.namespace == "PSU" &&
          target.data_product ==
          "SEIRS_model/parameters" && target.version == "1.0.0" &&
          target.component == "c"
    @test isnothing(DataPipeline.ExistingDataProduct("PSU:a").version)
    @test isnothing(DataPipeline.ExistingDataProduct("PSU:a").component)
    @test_throws ArgumentError DataPipeline.ExistingDataProduct("a")
    @test DataPipeline.ExistingDataProduct("PSU", "SEIRS_model/parameters",
                                           "1.0.0", component = "c") == target
    # A bare string to raise_issue: a config name, unless it holds a colon
    @test DataPipeline._astarget("a/b") == DataPipeline.ConfigDataProduct("a/b")
    @test DataPipeline._astarget("PSU:a/b@v1.0.0") ==
          DataPipeline.ExistingDataProduct("PSU:a/b@v1.0.0")
end

end
