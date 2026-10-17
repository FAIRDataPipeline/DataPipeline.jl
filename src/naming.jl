# SPDX-License-Identifier: LGPL-3.0-or-later

# The pipeline's naming convention, and the one form in which a registered data
# product is named outside the working config: `namespace:name@version`, or
# `namespace:name` for its newest version, as `fair` writes one.

# What a namespace is made of: ASCII letters, digits, `_` and `-`. A component
# name is parts of the same joined by `/`. A data product name is too, and a
# part may hold `.` between its first and last characters: a name is a folder
# structure in the data store, where a part beginning with a period would be
# a hidden folder and one ending with a period loses it on Windows
const NAMESPACE_PATTERN = r"^[A-Za-z0-9_-]+$"
const COMPONENT_PATTERN = r"^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$"
const DATA_PRODUCT_PATTERN = r"^[A-Za-z0-9_-](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?(?:/[A-Za-z0-9_-](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?)*$"

# `${{RUN_ID}}` in a name to be written, replaced by the run's uuid at finalise
const RUN_ID_PLACEHOLDER = r"\$\{\{\s*RUN_ID\s*\}\}"

# The namespace, name and version that `namespace:name@version` names: the
# version `nothing` when there is none, the namespace `default` when there is
# none and an error with no default; both checked against the convention, and
# the version written in full
function _parsedataproduct(text::AbstractString;
                           default::Union{Nothing, AbstractString} = nothing)
    text = String(text)
    namespace, rest = default, text
    colon = findfirst(':', text)
    if !isnothing(colon)
        namespace = text[1:prevind(text, colon)]
        rest = text[nextind(text, colon):end]
    end
    isnothing(namespace) &&
        throw(ArgumentError("'$text' names no namespace: a registered data product is named `namespace:name@version`, or `namespace:name` for its newest version"))
    name, version = rest, nothing
    at = findlast('@', rest)
    if !isnothing(at)
        name = rest[1:prevind(rest, at)]
        version = _releaseversion(rest[nextind(rest, at):end],
                                  keyword = "version")
    end
    return (namespace = _checknamespace(namespace),
            name = _checkdataproduct(name), version = version)
end

# A data product's name as the pipeline writes it: `namespace:name@vX.Y.Z`,
# or `namespace:name` with no version
function _dataproductname(namespace::AbstractString, name::AbstractString,
                          version::Union{Nothing, AbstractString,
                                         VersionNumber} = nothing)
    return isnothing(version) ? "$namespace:$name" :
           "$namespace:$name@v$version"
end

# The convention, applied to a namespace, a data product name (which may hold
# `${{RUN_ID}}`) and a component name: an `ArgumentError` names what is wrong
function _checknamespace(namespace::AbstractString)
    occursin(NAMESPACE_PATTERN, namespace) ||
        throw(ArgumentError("'$namespace' is not a namespace: one holds ASCII letters, digits, '_' and '-' only"))
    return String(namespace)
end
function _checkdataproduct(name::AbstractString)
    occursin(DATA_PRODUCT_PATTERN, replace(name, RUN_ID_PLACEHOLDER => "id")) ||
        throw(ArgumentError("'$name' is not a data product name: one holds ASCII letters, digits, '_', '-' and '.', in parts joined by '/', no part beginning or ending with '.'"))
    return String(name)
end
function _checkcomponent(component::AbstractString)
    occursin(COMPONENT_PATTERN, component) ||
        throw(ArgumentError("'$component' is not a component name: one holds ASCII letters, digits, '_' and '-', in parts joined by '/'"))
    return String(component)
end
