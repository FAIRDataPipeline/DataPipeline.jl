# SPDX-License-Identifier: LGPL-3.0-or-later

# Released names kept for one release after their replacement, newest release
# first: a release's section is deleted whole once that release has passed.

# == Deprecated in 0.55.0 ==

# `identify(folder)`, a git repository named by position, is replaced by
# `identify(repo = folder)`; the method serves files too, so the warning is in
# `identify` itself

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
