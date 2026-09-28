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
    r = DataPipeline.RegistryEndpoint(get(ENV, "FDP_TEST_REGISTRY",
                                          DataPipeline.DEFAULT_REGISTRY_URL),
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

end
