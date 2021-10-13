module TestCore

using Dates
using DataPipeline
using Test

Test.@testset "_convertquery()" begin
    # Test boolean
    test_boolean = DataPipeline._convertquery(Dict("public" => true))
    @test test_boolean == "?public=true"

    # Test strings
    test_string = DataPipeline._convertquery(Dict("name" => "string/1"))
    @test test_string == "?name=string%2F1"

    # Test multiple key-value pairs
    test_string2 = DataPipeline._convertquery(Dict("description" => "Short description", 
                                                   "key" => "value"))
    @test test_string2 == "?key=value&description=Short%20description"

    # Test datetimes
    rt = Dates.now()
    rt = Dates.format(rt, "yyyy-mm-dd HH:MM:SS")
    test_date = DataPipeline._convertquery(Dict("run_date" => rt))
    ans = replace(replace(rt, s":" => s"%3A"), s" " => s"%20")
    @test test_date == "?run_date=$ans"

    # Test URLs
    namespace_query = Dict("namespace" => "http://localhost:8000/api/namespace/19/")
    test_url = DataPipeline._convertquery(namespace_query)
    @test test_url == "?namespace=19"

    # Test URLs in array
    author_query = Dict("authors" => ["http://localhost:8000/api/author/1/", 
                        "http://localhost:8000/api/author/2/"])
    test_url = DataPipeline._convertquery(author_query)
    @test test_url == "?authors=1,2"
end

# Test.@testset "_getfilehash()" begin
#     DataPipeline._getfilehash()
# end

Test.@testset "_gettoken()" begin
    token = DataPipeline._gettoken()
    tmp = match(r"token (.*)", token)
    @test length(tmp[1]) == 40
end

end