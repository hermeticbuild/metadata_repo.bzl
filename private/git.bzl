"""git_repository repository rule that adds package metadata, including the PURL vcs_url qualifier.

The cloning logic is adapted from @bazel_tools//tools/build_defs/repo:git.bzl (Apache-2.0), whose
implementation is private and therefore cannot be reused directly.
"""

load("@bazel_tools//tools/build_defs/repo:cache.bzl", "CANONICAL_ID_DOC", "DEFAULT_CANONICAL_ID_ENV")
load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "get_auth", "patch", "update_attrs")
load(":http.bzl", "build_file_with_package_metadata", "build_metadata_purl", "repo_file_with_package_metadata")

def build_vcs_url(remote, revision):
    """Builds a PURL vcs_url qualifier value (pip / SPDX syntax): <vcs>+<transport>://<host>/<path>@<revision>.

    Credentials embedded in http(s) remotes are dropped so they do not leak into SBOMs.
    """
    url = remote
    if "://" in url:
        scheme, rest = url.split("://", 1)
        if scheme.startswith("git+"):
            scheme = scheme[len("git+"):]
        authority, slash, path = rest.partition("/")
        if scheme in ("http", "https") and "@" in authority:
            authority = authority.rsplit("@", 1)[1]
        url = "{}://{}{}{}".format(scheme, authority, slash, path)
    elif url.startswith("/"):
        url = "file://" + url
    elif ":" in url:
        # scp-like syntax: [user@]host:path
        host, path = url.split(":", 1)
        url = "ssh://{}/{}".format(host, path.lstrip("/"))
    else:
        fail("Cannot derive a vcs_url from remote '{}'".format(remote))
    url = "git+" + url
    return "{}@{}".format(url, revision) if revision else url

def _replace_tokens(value, replacements):
    if not value:
        return value
    for key, replacement in replacements.items():
        value = value.replace(key, replacement)
    return value

def _checkout_path(ctx):
    root = ctx.path(".")
    if ctx.attr.add_prefix:
        add_prefix_root = root.get_child(ctx.attr.add_prefix)
        if add_prefix_root != root and not str(add_prefix_root).startswith(str(root) + "/"):
            fail("add_prefix '{}' escaped the base directory of '{}': '{}'".format(ctx.attr.add_prefix, str(root), str(add_prefix_root)))
        return add_prefix_root
    return root

def _ctx_with_expanded_refs(ctx):
    """Returns a stand-in for ctx, as expected by git_repo, whose tag and branch have tokens expanded."""
    replacements = {
        "{name}": ctx.name,
        "{version}": ctx.attr.version,
    }
    replacements.update(ctx.attr.substitutions)
    attrs = {name: getattr(ctx.attr, name) for name in dir(ctx.attr)}
    attrs["tag"] = _replace_tokens(ctx.attr.tag, replacements)
    attrs["branch"] = _replace_tokens(ctx.attr.branch, replacements)
    return struct(
        attr = struct(**attrs),
        delete = ctx.delete,
        execute = ctx.execute,
        name = ctx.name,
        os = ctx.os,
        path = ctx.path,
        report_progress = ctx.report_progress,
        symlink = ctx.symlink,
    )

def _clone_or_update_repo(ctx):
    if ((ctx.attr.tag and ctx.attr.commit) or
        (ctx.attr.tag and ctx.attr.branch) or
        (ctx.attr.commit and ctx.attr.branch)):
        fail("At most one of commit, tag, or branch may be provided")

    checkout_path = _checkout_path(ctx)
    git_ = git_repo(_ctx_with_expanded_refs(ctx), str(checkout_path))

    if ctx.attr.strip_prefix:
        strip_prefix_path = checkout_path.get_child(ctx.attr.strip_prefix)
        if not strip_prefix_path.exists:
            fail("strip_prefix at {} does not exist in repo".format(ctx.attr.strip_prefix))
        if not strip_prefix_path.is_dir:
            fail("strip_prefix at {} is not a directory".format(ctx.attr.strip_prefix))

        strip_prefix_path = strip_prefix_path.realpath
        checkout_realpath = checkout_path.realpath
        strip_prefix_realpath = str(strip_prefix_path).lower()
        git_metadata_path = str(checkout_realpath.get_child(".git")).lower()
        if (strip_prefix_realpath == git_metadata_path or
            strip_prefix_realpath.startswith(git_metadata_path + "/")):
            fail("strip_prefix at {} refers to Git metadata".format(ctx.attr.strip_prefix))
        if strip_prefix_path != checkout_realpath:
            if not str(strip_prefix_path).startswith(str(checkout_realpath) + "/"):
                fail("strip_prefix at {} escaped the checkout directory".format(ctx.attr.strip_prefix))

            existing_entries = {
                entry.basename.lower(): True
                for entry in checkout_path.readdir() + strip_prefix_path.readdir()
            }
            strip_prefix_tmp_name = ".bazel_git_strip_prefix"
            for _ in existing_entries:
                if strip_prefix_tmp_name not in existing_entries:
                    break
                strip_prefix_tmp_name += "_"
            strip_prefix_tmp_path = checkout_path.get_child(strip_prefix_tmp_name)

            # Keep the selected subtree while removing the rest of the checkout.
            ctx.rename(strip_prefix_path, strip_prefix_tmp_path)
            for entry in checkout_path.readdir():
                if entry.basename != strip_prefix_tmp_name:
                    ctx.delete(entry)
            for entry in strip_prefix_tmp_path.readdir():
                ctx.rename(entry, checkout_path.get_child(entry.basename))
            ctx.delete(strip_prefix_tmp_path)

    if ctx.attr.shallow_since:
        return {"commit": git_.commit, "shallow_since": git_.shallow_since}
    return {"commit": git_.commit}

def _update_git_attrs(orig, keys, override):
    result = update_attrs(orig, keys, override)

    # Once the commit is known, drop the other means of specifying it.
    if "commit" in result:
        result.pop("tag", None)
        result.pop("branch", None)
    return result

def _write_workspace_file(ctx):
    if ctx.attr.workspace_file and ctx.attr.workspace_file_content:
        fail("Only one of 'workspace_file' and 'workspace_file_content' may be specified")
    if ctx.attr.workspace_file:
        ctx.file("WORKSPACE", ctx.read(ctx.attr.workspace_file))
    elif ctx.attr.workspace_file_content:
        ctx.file("WORKSPACE", ctx.attr.workspace_file_content)
    else:
        ctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(ctx.name))

def _read_build_file_content(ctx):
    if ctx.attr.build_file:
        return ctx.read(ctx.attr.build_file)
    return ctx.attr.build_file_content if ctx.attr.build_file_content else None

def _git_repository_impl(ctx):
    if ctx.attr.build_file and ctx.attr.build_file_content:
        fail("Only one of 'build_file' and 'build_file_content' may be specified")
    if ctx.attr.sparse_checkout_patterns and ctx.attr.sparse_checkout_file:
        fail("Only one of 'sparse_checkout_patterns' and 'sparse_checkout_file' may be specified")

    update = _clone_or_update_repo(ctx)
    commit = update["commit"]
    _write_workspace_file(ctx)
    patch(ctx)

    # Downloaded after patching, as in native git_repository, so the registry's module file wins.
    if ctx.attr.remote_module_file_urls:
        ctx.download(
            ctx.attr.remote_module_file_urls,
            "MODULE.bazel",
            auth = get_auth(ctx, ctx.attr.remote_module_file_urls),
            integrity = ctx.attr.remote_module_file_integrity,
        )

    ctx.delete(_checkout_path(ctx).get_child(".git"))

    replacements = {
        "{commit}": commit,
        "{name}": ctx.name,
        "{version}": ctx.attr.version,
    }
    replacements.update(ctx.attr.substitutions)
    vcs_url = build_vcs_url(ctx.attr.remote, commit)
    metadata_purl = build_metadata_purl(
        name = ctx.name,
        version = ctx.attr.version,
        purl_pattern = _replace_tokens(ctx.attr.purl_pattern, replacements),
        vcs_url = vcs_url,
        qualifiers = ctx.attr.qualifiers,
    )
    ctx.file("BUILD.bazel", build_file_with_package_metadata(metadata_purl, _read_build_file_content(ctx), license = ctx.attr.license))
    ctx.file("REPO.bazel", repo_file_with_package_metadata())

    if ctx.attr.commit:
        return ctx.repo_metadata(reproducible = True)
    return ctx.repo_metadata(attrs_for_reproducibility = _update_git_attrs(ctx.attr, _GIT_ATTRS.keys(), update))

_GIT_ATTRS = {
    "add_prefix": attr.string(
        doc = "Destination directory relative to the repository directory, matching native git_repository.",
    ),
    "branch": attr.string(
        doc = "Branch to check out. Supports {name}, {version} and keys from substitutions. At most one of branch, tag, or commit may be specified.",
    ),
    "build_file": attr.label(
        allow_single_file = True,
        doc = "File to use as the repository BUILD file. The package_metadata target is appended. Mutually exclusive with build_file_content.",
    ),
    "build_file_content": attr.string(
        doc = "BUILD file content for the repository. The package_metadata target is appended.",
    ),
    "canonical_id": attr.string(
        doc = CANONICAL_ID_DOC,
    ),
    "commit": attr.string(
        doc = "Commit to check out. At most one of branch, tag, or commit may be specified.",
    ),
    "init_submodules": attr.bool(
        doc = "Whether to clone submodules.",
    ),
    "patch_args": attr.string_list(
        doc = "Arguments passed to the patch tool, matching native git_repository.",
    ),
    "patch_cmds": attr.string_list(
        doc = "Shell commands run after patches are applied, matching native git_repository.",
    ),
    "patch_cmds_win": attr.string_list(
        doc = "Windows-specific patch_cmds; falls back to patch_cmds when empty.",
    ),
    "patch_strip": attr.int(
        doc = "Equivalent to inserting -pN at the start of patch_args.",
    ),
    "patch_tool": attr.string(
        doc = "Patch executable to use instead of the native patch implementation.",
    ),
    "license": attr.label(
        doc = "Optional license target (for example from @package_metadata//licenses) added to the attributes of the generated :package_metadata target. Resolved from the module using the rule, so it needs a bazel_dep on the repository defining it.",
    ),
    "patches": attr.label_list(
        doc = "Patch files to apply after cloning, matching native git_repository.",
    ),
    "purl_pattern": attr.string(
        mandatory = True,
        doc = "PURL pattern. Supports {name}, {version}, and {commit} (the resolved commit), plus keys from substitutions. Common qualifiers are merged after parsing; the vcs_url qualifier is git+<remote>@<resolved commit>; override it through qualifiers.",
    ),
    "qualifiers": attr.string_dict(
        doc = "Additional PURL qualifiers to merge into the parsed PURL.",
    ),
    "recursive_init_submodules": attr.bool(
        doc = "Whether to clone submodules recursively.",
    ),
    "remote": attr.string(
        mandatory = True,
        doc = "The URI of the remote Git repository.",
    ),
    "remote_module_file_integrity": attr.string(
        doc = "For internal use only, matching native git_repository.",
    ),
    "remote_module_file_urls": attr.string_list(
        doc = "For internal use only, matching native git_repository.",
    ),
    "remote_patch_strip": attr.int(
        doc = "Number of leading path components to strip from remote patches.",
    ),
    "remote_patches": attr.string_dict(
        doc = "Map of remote patch URL to integrity value, matching native git_repository.",
    ),
    "shallow_since": attr.string(
        doc = "Optional date, not after the specified commit, enabling a shallow clone. Not recommended; see native git_repository.",
    ),
    "sparse_checkout_file": attr.label(
        doc = "File with .gitignore-style patterns for a sparse checkout. Mutually exclusive with sparse_checkout_patterns.",
    ),
    "sparse_checkout_patterns": attr.string_list(
        doc = "Patterns for a sparse checkout of the repository.",
    ),
    "strip_prefix": attr.string(
        doc = "Directory prefix to strip from the checked out files, matching native git_repository.",
    ),
    "substitutions": attr.string_dict(
        doc = "Additional literal replacements used by purl_pattern, tag and branch. Keys are replaced as-is.",
    ),
    "tag": attr.string(
        doc = "Tag to check out. Supports {name}, {version} and keys from substitutions, for example v{version}. At most one of branch, tag, or commit may be specified.",
    ),
    "verbose": attr.bool(),
    "version": attr.string(
        doc = "Optional version used to expand purl_pattern.",
    ),
    "workspace_file": attr.label(
        doc = "File to use as the repository WORKSPACE file. Mutually exclusive with workspace_file_content.",
    ),
    "workspace_file_content": attr.string(
        doc = "Content for the repository WORKSPACE file. Mutually exclusive with workspace_file.",
    ),
}

git_repository = repository_rule(
    implementation = _git_repository_impl,
    attrs = _GIT_ATTRS,
    environ = [DEFAULT_CANONICAL_ID_ENV],
    doc = "Clones a git repository, then adds a package_metadata target whose PURL carries the vcs_url qualifier.",
)
