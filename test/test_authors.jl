# SPDX-License-Identifier: LGPL-3.0-or-later

module TestAuthors

using DataPipeline
using Dates
using Test

uid = DataPipeline._randomhash()
cpath = joinpath("coderun", Dates.format(Dates.now(), "yyyymmdd-HHMMSS"),
                 "authors.yaml")
config = DataPipeline._createconfig(cpath)
handle = DataPipeline.initialise(config, config)
registry = handle.registry

# Identifiers that are URLs of the two kinds and belong to this run alone
orcid(n) = "https://orcid.org/$(uid[1:16])-$n"
ror(n) = "https://ror.org/$(uid[1:9])$n"

# The same identifier written with http:
insecure(identifier) = replace(identifier, "https:" => "http:")

# A TOML file of authors holding these lines
function authors_file(lines::AbstractString...)
    path = joinpath(mktempdir(), "authors.toml")
    write(path, join(lines, "\n"), "\n")
    return path
end

# The line of such a file for an author
line(name, identifier) = "\"$name\" = \"$identifier\""

# Register an author as another run would have: with any of a name and an
# identifier, and with nothing kept in this run's handle. Return its URL.
function registered_before(data::Pair...)
    return DataPipeline._createentry(registry, "author", Dict(data...))["url"]
end

# The registry's authors of exactly this name, newest first
function named(name)
    return [author
            for author in DataPipeline._getentries(registry, "author",
                                                   Dict("name" => name))
            if author["name"] == name]
end

# The registry's author with this identifier, or `nothing`
function identified(identifier)
    return DataPipeline._getentry(registry, "author",
                                  Dict("identifier" => identifier))
end

# What is logged when a name is given for an identifier that the registry
# holds under another, or under none
function told(identifier, held, name)
    known = isnothing(held) ? "with no name" : "as '$held'"
    return (:info, Regex("$identifier $known: an author cited as '$name'"))
end

# The message of the `ArgumentError` a call throws
function message_of(call::Function)
    try
        call()
    catch e
        e isa ArgumentError || rethrow()
        return e.msg
    end
    return error("nothing was thrown")
end

Test.@testset "register_authors!()" begin
    person = "Given M. Family $uid"
    organisation = "An Example Institute, with a comma $uid"
    other = "Another Person $uid"
    file = authors_file(line(person, orcid(1)),
                        "# an organisation has a ROR id",
                        line(organisation, ror(1)))

    # An author is a pair or a line of a file: each is registered with its
    # identifier and kept for the run, and the names come back sorted
    @test register_authors!(handle) == String[]
    @test isempty(handle.authors)
    @test register_authors!(handle, other => orcid(2), file) ==
          [organisation, other, person]
    @test only(named(person))["identifier"] == orcid(1)
    @test only(named(organisation))["identifier"] == ror(1)
    @test only(named(other))["identifier"] == orcid(2)
    registered = Dict(person => [orcid(1)], organisation => [ror(1)],
                      other => [orcid(2)])
    @test handle.authors == registered
    @test occursin("authors: 3", sprint(show, MIME("text/plain"), handle))

    # Given again, in one call or another, nothing is added and nothing said
    names = @test_logs register_authors!(handle, file, other => orcid(2), file)
    @test names == [organisation, other, person]
    @test length(named(person)) == 1
    @test handle.authors[person] == [orcid(1)]
    @test length(handle.authors) == 3

    # An identifier written with http: is the one with https:
    plain = "Plain Address $uid"
    @test register_authors!(handle, plain => insecure(orcid(3))) == [plain]
    @test only(named(plain))["identifier"] == orcid(3)
    @test isnothing(identified(insecure(orcid(3))))
    again = authors_file(line(plain, insecure(orcid(3))))
    @test_logs register_authors!(handle, plain => orcid(3), again)
    @test handle.authors[plain] == [orcid(3)]
    @test length(named(plain)) == 1

    # An identifier given several names keeps the first, the arguments taken
    # in order, and the others stand for the same author
    full, short = "Kamel Example $uid", "K. Example $uid"
    second = told(orcid(4), full, short)
    @test_logs second register_authors!(handle, full => orcid(4),
                                        short => orcid(4))
    @test identified(orcid(4))["name"] == full
    @test isempty(named(short))
    @test handle.authors[full] == handle.authors[short] == [orcid(4)]

    # ... and a file's authors in order of name, whatever that of its lines
    spelt = ["$letter Example $uid"
             for letter in ("Alpha", "Beta", "Mu", "Zed")]
    spellings = authors_file(line.(reverse(spelt), orcid(5))...)
    second, third, fourth = (told(orcid(5), spelt[1], name)
                             for name in spelt[2:4])
    @test_logs second third fourth register_authors!(handle, spellings)
    @test identified(orcid(5))["name"] == spelt[1]
    @test first.(DataPipeline._readauthors(spellings)) == spelt

    # One the registry holds already keeps what it has there, a name or none
    before = "Held Before $uid"
    registered_before("name" => before, "identifier" => orcid(6))
    registered_before("identifier" => orcid(7))
    respelt, unnamed = "H. Before $uid", "Named Here $uid"
    renamed = told(orcid(6), before, respelt)
    nameless = told(orcid(7), nothing, unnamed)
    @test_logs renamed nameless register_authors!(handle, respelt => orcid(6),
                                                  unnamed => orcid(7))
    @test identified(orcid(6))["name"] == before
    @test isnothing(identified(orcid(7))["name"])
    @test isempty(named(respelt)) && isempty(named(unnamed))
    @test handle.authors[respelt] == [orcid(6)]
    @test handle.authors[unnamed] == [orcid(7)]

    # Several authors may share a name, each with an identifier of its own
    shared = "John Shared $uid"
    names = @test_logs register_authors!(handle, shared => orcid(8),
                                         shared => orcid(9))
    @test names == [shared]
    @test [author["identifier"] for author in named(shared)] ==
          [orcid(9), orcid(8)]
    @test handle.authors[shared] == [orcid(8), orcid(9)]

    # What cannot be read is refused whole, saying what is wrong, and nothing
    # is registered or kept: no file, what is not TOML, an identifier that is
    # not text or not a URL, and a name the registry will not hold
    good = "Good Person $uid"
    kept = deepcopy(handle.authors)
    bare = "0000-0002-1825-0097"
    unreadable = [(joinpath(mktempdir(), "no.toml"), "no file of authors"),
        (authors_file("\"Unclosed $uid = \"$(orcid(11))\""),
         "cannot read"),
        (authors_file("\"Numbered $uid\" = 6"),
         "no identifier in text"),
        (authors_file("[section]", line("name", orcid(11))),
         "no identifier in text"),
        (authors_file(line("Bare $uid", bare)), "not a URL"),
        ("Bare $uid" => bare, "not a URL"),
        (authors_file(line("Starred* $uid", orcid(11))),
         "cannot hold"),
        ("Who? $uid" => orcid(11), "cannot hold"),
        (" " => orcid(11), "no name")]
    for (author, said) in unreadable
        msg = message_of() do
            return register_authors!(handle, good => orcid(10), author)
        end
        @test occursin(said, msg)
    end
    @test isnothing(identified(orcid(10))) && isnothing(identified(orcid(11)))
    @test isempty(named(good))
    @test handle.authors == kept
end

Test.@testset "the registry's author for a cited name" begin
    # A name registered in this run is the author with its identifier,
    # whatever name the registry has for that author
    full, short = "Cited Example $uid", "C. Example $uid"
    second = told(orcid(20), full, short)
    @test_logs second register_authors!(handle, full => orcid(20),
                                        short => orcid(20))
    author = identified(orcid(20))["url"]
    @test DataPipeline._authorurl(handle, full) == author
    @test DataPipeline._authorurl(handle, short) == author
    @test isempty(named(short))

    # One registered with two identifiers cannot say which is meant: it is an
    # author by the name alone, the same one each time, and a warning says so
    twin, own = "Twin Example $uid", "Twin A. Example $uid"
    register_authors!(handle, twin => orcid(21), twin => orcid(22))
    unsure = (:warn,
              Regex("'$twin' is registered in this run with 2 identifiers, $(orcid(21)), $(orcid(22))"))
    unidentified = @test_logs unsure DataPipeline._authorurl(handle, twin)
    @test [author["identifier"] for author in named(twin)] ==
          [nothing, orcid(22), orcid(21)]
    @test first(named(twin))["url"] == unidentified
    again = @test_logs unsure DataPipeline._authorurl(handle, twin)
    @test again == unidentified
    @test length(named(twin)) == 3
    # ... while a name that only one of them has is that one
    renamed = told(orcid(21), twin, own)
    @test_logs renamed register_authors!(handle, own => orcid(21))
    @test DataPipeline._authorurl(handle, own) == identified(orcid(21))["url"]

    # A name that is not registered in the run is an author by the name alone.
    # One the registry has not got is registered, once
    cited = "Cited Only By Name $uid"
    by_name = @test_logs DataPipeline._authorurl(handle, cited)
    @test only(named(cited))["url"] == by_name
    @test isnothing(only(named(cited))["identifier"])
    @test DataPipeline._authorurl(handle, cited) == by_name
    @test length(named(cited)) == 1
    @test !haskey(handle.authors, cited)

    # Of several by the name alone it is the first that was registered
    registered_before("name" => cited)
    @test length(named(cited)) == 2
    @test DataPipeline._authorurl(handle, cited) == by_name

    # One that the registry holds with an identifier is not taken for it,
    # whether or not there is one by the name alone
    elsewhere = registered_before("name" => cited, "identifier" => orcid(23))
    @test DataPipeline._authorurl(handle, cited) == by_name
    lone = "Identified Elsewhere $uid"
    registered_before("name" => lone, "identifier" => orcid(24))
    unidentified = @test_logs DataPipeline._authorurl(handle, lone)
    @test [author["identifier"] for author in named(lone)] ==
          [nothing, orcid(24)]
    @test first(named(lone))["url"] == unidentified

    # ... until the run registers the name with that identifier
    @test_logs register_authors!(handle, cited => orcid(23))
    @test DataPipeline._authorurl(handle, cited) == elsewhere
    @test length(named(cited)) == 3

    # The name is matched exactly: another spelling, or another case, is
    # another author
    for spelling in (lowercase(cited), "C. " * cited)
        @test isempty(named(spelling))
        @test DataPipeline._authorurl(handle, spelling) != by_name
        @test isnothing(only(named(spelling))["identifier"])
    end
    # ... and one the registry will not hold is refused
    @test_throws ArgumentError DataPipeline._authorurl(handle, "Who? $uid")
end

end
