# SPDX-License-Identifier: LGPL-3.0-or-later

# Released names kept for one release after their replacement, newest release
# first: a release's section is deleted whole once that release has passed.

# == Deprecated in 0.55.0 ==

# The calls that change what a run registers, before they took the `!` every
# such call carries; each is exported here, in place
@deprecate raise_issue raise_issue!
@deprecate read_array read_array!
@deprecate read_table read_table!
@deprecate read_estimate read_estimate!
@deprecate read_distribution read_distribution!
@deprecate write_array write_array!
@deprecate write_table write_table!
@deprecate write_estimate write_estimate!
@deprecate write_distribution write_distribution!

# `identify(folder; commits)`, a git repository named by position, is replaced
# by a selection holding its repository, `identify(AncestorCommits(repo =
# folder))`; the method serves files too, so the warning is in `identify`
# itself, and this is the selection it was given, made of that repository
function _withrepo(selection::AncestorCommits, repo::String)
    return AncestorCommits(of = selection.of, including = selection.including,
                           repo = repo, dirty = selection.dirty)
end
function _withrepo(selection::CheckedOutCommit, repo::String)
    return CheckedOutCommit(repo = repo, dirty = selection.dirty)
end
function _withrepo(selection::AllCommits, repo::String)
    return AllCommits(repo = repo, dirty = selection.dirty)
end
function _withrepo(selection::NamedCommit, repo::String)
    return NamedCommit(selection.name, repo = repo, dirty = selection.dirty)
end

# A registered data product named by its three parts, before the one form
# `namespace:name@version`
function ExistingDataProduct(namespace::AbstractString,
                             data_product::AbstractString,
                             version::AbstractString;
                             component::Union{Nothing, AbstractString} = nothing)
    Base.depwarn("`ExistingDataProduct(namespace, data_product, version)` is deprecated: name the data product `namespace:name@version`",
                 :ExistingDataProduct)
    return ExistingDataProduct(_dataproductname(namespace, data_product,
                                                version); component)
end
