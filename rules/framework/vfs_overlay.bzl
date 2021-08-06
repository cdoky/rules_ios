load("//rules:providers.bzl", "FrameworkInfo")
load("//rules:features.bzl", "feature_names")

FRAMEWORK_SEARCH_PATH = "/build_bazel_rules_ios/frameworks"

VFSOverlayInfo = provider(
    doc = "Propagates vfs overlays",
    fields = {
        "files": "depset with overlays",
        "vfs_info": "intneral obj",
    },
)

# Computes the "back" segment for a path length
def _make_relative_prefix(length):
    dots = "../"
    prefix = ""
    for i in range(0, length):
        prefix += dots
    return prefix

# Internal to swift and clang - LLVM `VirtualFileSystem` object can
# serialize paths relative to the absolute path of the overlay. This
# requires the paths are relative to the overlay. While deriving the
# in-memory tree roots, it pre-pends the prefix of the `vfsoverlay` path
# to each of the entries.
def _get_external_contents(prefix, path_str):
    return prefix + path_str

def _get_vfs_parent(ctx):
    return (ctx.bin_dir.path + "/" + ctx.build_file_path)

# Search a VFS json's contents for a name
def _vfs_json_lookup_contents(contents, name):
    for c in contents:
        if name == c["name"]:
            return c
    return None

# Builds out the VFS subtrees for a given set of paths. This is useful to
# construct an in-memory rep of a tree on the file system
def _build_subtrees(paths, vfs_prefix):

    # This saves having to loop the entire VFS again to translate to
    # JSON at the trade-off of having extra lookups rarely
    subdirs = {"contents": [], "type": "directory", "name": "root"}
    for path_info in paths:
        path = path_info.framework_path

        parts = path.split("/")

        # current pointer to the current subdirs while walking the path
        curr_subdirs = subdirs

        # Loop the _framework_ path and add each dir to the current tree.
        # Assume the last bit is a file then add it as a file  This loop is
        # quite short ( e.g. O(1) since we loop the VFS path ( e.g. X.h ) and
        # not the file path.
        idx = 0
        for part in parts:
            if idx == len(parts) - 1:
                ext_c = _get_external_contents(vfs_prefix, path_info.path)
                curr_subdirs["contents"].append({"name": part, "type": "file", "external-contents": ext_c})
                break

            # Lookup the next, or append it
            next_subdirs = _vfs_json_lookup_contents(curr_subdirs["contents"], part)
            if not next_subdirs:
                next_subdirs = {"contents": [], "type": "directory", "name": part}
                curr_subdirs["contents"].append(next_subdirs)
            curr_subdirs = next_subdirs
            idx += 1
    return subdirs

# Make roots for a given framework. For now this is done in starlark for speed
# and incrementality. For imported frameworks, there is additional search paths
# enabled
def _make_root(vfs_parent, bin_dir_path, build_file_path, framework_name, root_dir, extra_search_paths, module_map, hdrs, private_hdrs, has_swift):
    headers_contents = []
    private_headers_contents = []
    vfs_prefix = _make_relative_prefix(len(vfs_parent.split("/")) - 1)
    if extra_search_paths:
        sub_dir = "Headers"
        paths = []
        for hdr in hdrs:
            path = hdr.path

            # We need to nest this path under the search_path.
            last_parts = path.split(extra_search_paths + "/" + sub_dir + "/")
            if len(last_parts) < 2:
                # If the search path doesn't reside in the path then skip.
                # Consider pulling out the the sub_dir here, the re-appending
                # below.
                continue
            paths.append(struct(path = hdr.path, framework_path = last_parts[1]))
        subtrees = _build_subtrees(paths, vfs_prefix)
        headers_contents.extend(subtrees["contents"])

        # Same as above
        sub_dir = "PrivateHeaders"
        paths = []
        for hdr in private_hdrs:
            path = hdr.path
            last_parts = path.split(extra_search_paths + "/" + sub_dir + "/")
            if len(last_parts) < 2:
                continue
            paths.append(struct(path = hdr.path, framework_path = last_parts[1]))
        subtrees = _build_subtrees(paths, vfs_prefix)
        private_headers_contents.extend(subtrees["contents"])

    modules_contents = []
    if len(module_map):
        modules_contents.append({
            "type": "file",
            "name": "module.modulemap",
            "external-contents": _get_external_contents(vfs_prefix, module_map[0].path),
        })

    modules = []
    if len(modules_contents):
        modules = [{
            "name": "Modules",
            "type": "directory",
            "contents": modules_contents,
        }]

    headers_contents.extend([
        {
            "type": "file",
            "name": file.basename,
            "external-contents": _get_external_contents(vfs_prefix, file.path),
        }
        for file in hdrs
    ])

    private_headers_contents.extend([
        {
            "type": "file",
            "name": file.basename,
            "external-contents": _get_external_contents(vfs_prefix, file.path),
        }
        for file in private_hdrs
    ])

    headers = []
    if len(headers_contents):
        headers = [{
            "name": "Headers",
            "type": "directory",
            "contents": headers_contents,
        }]

    private_headers = []
    if len(private_headers_contents):
        private_headers = [{
            "name": "PrivateHeaders",
            "type": "directory",
            "contents": private_headers_contents,
        }]

    roots = []
    if len(headers) or len(private_headers) or len(modules):
        roots.append({
            "name": root_dir,
            "type": "directory",
            "contents": headers + private_headers + modules,
        })
    if has_swift:
        roots.append(_vfs_swift_module_contents(bin_dir_path, build_file_path, vfs_prefix, framework_name, FRAMEWORK_SEARCH_PATH))

    return roots

def _vfs_swift_module_contents(bin_dir_path, build_file_path, vfs_prefix, framework_name, root_dir):
    # Forumlate the framework's swiftmodule - don't have the swiftmodule when
    # creating with apple_library. Consider removing that codepath to make this
    # and other situations easier
    base_path = "/".join(build_file_path.split("/")[:-1])
    rooted_path = bin_dir_path + "/" + base_path

    # Note: Swift translates the input framework name to this because - is an
    # invalid character in module name
    name = framework_name.replace("-", "_") + ".swiftmodule"
    external_contents = rooted_path + "/" + name
    return {
        "type": "file",
        "name": root_dir + "/" + name,
        "external-contents": _get_external_contents(vfs_prefix, external_contents),
    }

def _framework_vfs_overlay_impl(ctx):
    vfsoverlays = []

    # Conditionally collect and pass in the VFS overlay here.
    virtualize_frameworks = feature_names.virtualize_frameworks in ctx.features
    if virtualize_frameworks:
        for dep in ctx.attr.deps:
            if FrameworkInfo in dep:
                vfsoverlays.extend(dep[FrameworkInfo].vfsoverlay_infos)
            if VFSOverlayInfo in dep:
                vfsoverlays.append(dep[VFSOverlayInfo].vfs_info)

    vfs = make_vfsoverlay(
        ctx,
        hdrs = ctx.files.hdrs,
        module_map = ctx.files.modulemap,
        private_hdrs = ctx.files.private_hdrs,
        has_swift = ctx.attr.has_swift,
        merge_vfsoverlays = vfsoverlays,
        output = ctx.outputs.vfsoverlay_file,
        extra_search_paths = ctx.attr.extra_search_paths,
    )

    headers = depset([vfs.vfsoverlay_file])
    cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = headers,
        ),
    )
    return [
        apple_common.new_objc_provider(),
        cc_info,
        VFSOverlayInfo(
            files = depset([vfs.vfsoverlay_file]),
            vfs_info = vfs.vfs_info,
        ),
    ]

def _merge_vfs_infos(base, vfs_infos):
    for vfs_info in vfs_infos:
        base.update(vfs_info)
    return base

# Internally the "vfs obj" is represented as a dictionary, which is keyed on
# the name of the root. This is an opaque value to consumers
def _make_vfs_info(name, data):
    keys = {}
    keys[name] = data
    return keys

# Roots must be computed _relative_ to the vfs_parent. It is no longer possible
# to memoize VFS computations because of this.
def _roots_from_datas(vfs_parent, datas):
    roots = []
    for data in datas:
        roots.extend(_make_root(
            vfs_parent = vfs_parent,
            bin_dir_path = data.bin_dir_path,
            build_file_path = data.build_file_path,
            framework_name = data.framework_name,
            root_dir = data.framework_path,
            extra_search_paths = data.extra_search_paths,
            module_map = data.module_map,
            hdrs = data.hdrs,
            private_hdrs = data.private_hdrs,
            has_swift = data.has_swift,
        ))
    return roots

def make_vfsoverlay(ctx, hdrs, module_map, private_hdrs, has_swift, merge_vfsoverlays = [], extra_search_paths = None, output = None):
    framework_name = ctx.attr.framework_name
    framework_path = "{search_path}/{framework_name}.framework".format(
        search_path = FRAMEWORK_SEARCH_PATH,
        framework_name = framework_name,
    )

    vfs_parent = _get_vfs_parent(ctx)

    data = struct(
        bin_dir_path = ctx.bin_dir.path,
        build_file_path = ctx.build_file_path,
        framework_name = framework_name,
        framework_path = framework_path,
        extra_search_paths = extra_search_paths,
        module_map = module_map,
        hdrs = hdrs,
        private_hdrs = private_hdrs,
        has_swift = has_swift,
    )

    roots = _make_root(
        vfs_parent,
        bin_dir_path = ctx.bin_dir.path,
        build_file_path = ctx.build_file_path,
        framework_name = framework_name,
        root_dir = framework_path,
        extra_search_paths = extra_search_paths,
        module_map = module_map,
        hdrs = hdrs,
        private_hdrs = private_hdrs,
        has_swift = has_swift,
    )

    vfs_info = _make_vfs_info(framework_name, data)
    if len(merge_vfsoverlays) > 0:
        vfs_info = _merge_vfs_infos(vfs_info, merge_vfsoverlays)
        roots = _roots_from_datas(vfs_parent, vfs_info.values() + [data])

    if output == None:
        return struct(vfsoverlay_file = None, vfs_info = vfs_info)

    vfsoverlay_object = {
        "version": 0,
        "case-sensitive": True,
        "overlay-relative": True,
        "use-external-names": False,
        "roots": roots,
    }
    vfsoverlay_yaml = struct(**vfsoverlay_object).to_json()
    ctx.actions.write(
        content = vfsoverlay_yaml,
        output = output,
    )

    return struct(vfsoverlay_file = output, vfs_info = vfs_info)

framework_vfs_overlay = rule(
    implementation = _framework_vfs_overlay_impl,
    attrs = {
        "framework_name": attr.string(mandatory = True),
        "extra_search_paths": attr.string(mandatory = False),
        "has_swift": attr.bool(default = False),
        "modulemap": attr.label(allow_single_file = True),
        "hdrs": attr.label_list(allow_files = True),
        "private_hdrs": attr.label_list(allow_files = True, default = []),
        "deps": attr.label_list(allow_files = True, default = []),
    },
    outputs = {
        "vfsoverlay_file": "%{name}.yaml",
    },
)
