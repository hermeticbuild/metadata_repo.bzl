"""HTTP repository rules that add package metadata for downloaded artifacts."""

load("@package_metadata//purl:purl.bzl", "purl")
load("@bazel_tools//tools/build_defs/repo:cache.bzl", "DEFAULT_CANONICAL_ID_ENV", "get_default_canonical_id")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "download_remote_files", "get_auth", "patch", "symlink_files")

_BASE64 = {
    "A": 0,
    "B": 1,
    "C": 2,
    "D": 3,
    "E": 4,
    "F": 5,
    "G": 6,
    "H": 7,
    "I": 8,
    "J": 9,
    "K": 10,
    "L": 11,
    "M": 12,
    "N": 13,
    "O": 14,
    "P": 15,
    "Q": 16,
    "R": 17,
    "S": 18,
    "T": 19,
    "U": 20,
    "V": 21,
    "W": 22,
    "X": 23,
    "Y": 24,
    "Z": 25,
    "a": 26,
    "b": 27,
    "c": 28,
    "d": 29,
    "e": 30,
    "f": 31,
    "g": 32,
    "h": 33,
    "i": 34,
    "j": 35,
    "k": 36,
    "l": 37,
    "m": 38,
    "n": 39,
    "o": 40,
    "p": 41,
    "q": 42,
    "r": 43,
    "s": 44,
    "t": 45,
    "u": 46,
    "v": 47,
    "w": 48,
    "x": 49,
    "y": 50,
    "z": 51,
    "0": 52,
    "1": 53,
    "2": 54,
    "3": 55,
    "4": 56,
    "5": 57,
    "6": 58,
    "7": 59,
    "8": 60,
    "9": 61,
    "+": 62,
    "/": 63,
}

_HEX = "0123456789abcdef"
_POW2 = [1, 2, 4, 8, 16, 32, 64, 128]

def _byte_to_hex(byte):
    return _HEX[byte // 16] + _HEX[byte % 16]

def _base64_to_hex(value):
    clean = "".join(value.split(" ")).rstrip("=")
    output = []
    buffer = 0
    bits = 0
    for c in clean.elems():
        digit = _BASE64.get(c)
        if digit == None:
            fail("Invalid base64 character in integrity digest: {}".format(c))
        buffer = (buffer * 64) + digit
        bits += 6
        if bits >= 8:
            bits -= 8
            output.append(_byte_to_hex((buffer // _POW2[bits]) % 256))
    return "".join(output)

def _integrity_to_checksum_qualifier(integrity):
    checksums = []
    for item in integrity.split(" "):
        if not item:
            continue
        parts = item.split("-")
        if len(parts) != 2:
            fail("Invalid integrity value '{}': expected '<algorithm>-<base64 digest>'".format(item))
        checksums.append("{}:{}".format(parts[0].lower(), _base64_to_hex(parts[1])))
    return ",".join(checksums) if checksums else None

_BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

def _hex_to_base64(value):
    value = value.lower()
    if len(value) % 2 != 0:
        fail("Invalid hex digest: {}".format(value))
    data = []
    for i in range(0, len(value), 2):
        high = _HEX.find(value[i])
        low = _HEX.find(value[i + 1])
        if high < 0 or low < 0:
            fail("Invalid hex digest: {}".format(value))
        data.append(high * 16 + low)
    output = []
    for i in range(0, len(data), 3):
        chunk = data[i:i + 3]
        n = chunk[0] * 65536 + (chunk[1] if len(chunk) > 1 else 0) * 256 + (chunk[2] if len(chunk) > 2 else 0)
        output.append(_BASE64_ALPHABET[(n // 262144) % 64])
        output.append(_BASE64_ALPHABET[(n // 4096) % 64])
        output.append(_BASE64_ALPHABET[(n // 64) % 64] if len(chunk) > 1 else "=")
        output.append(_BASE64_ALPHABET[n % 64] if len(chunk) > 2 else "=")
    return "".join(output)

def integrity_values(*, sha256, integrity):
    """Returns the artifact checksums as a list of SRI strings."""
    if sha256:
        return ["sha256-{}".format(_hex_to_base64(sha256))]
    return [item for item in integrity.split(" ") if item]

def _checksum_qualifier(*, sha256, integrity):
    if sha256 and integrity:
        fail("Only one of 'sha256' or 'integrity' may be specified")
    if sha256:
        return "sha256:{}".format(sha256.lower())
    if integrity:
        return _integrity_to_checksum_qualifier(integrity)
    return None

def _verify_checksum_attrs(*, sha256, integrity):
    if not sha256 and not integrity:
        fail("One of 'sha256' or 'integrity' must be specified")
    if sha256 and integrity:
        fail("Only one of 'sha256' or 'integrity' may be specified")

def _replacement_values(*, name, version, sha256, integrity, substitutions = {}):
    values = {
        "{integrity}": integrity,
        "{name}": name,
        "{sha256}": sha256,
        "{version}": version,
    }
    values.update(substitutions)
    return values

def _replace_tokens(value, replacements):
    if value == None:
        return None
    for key, replacement in replacements.items():
        value = value.replace(key, replacement)
    return value

def _first_url(urls):
    return urls[0] if urls else None

def _basename(path):
    normalized = path.split("?")[0].split("#")[0]
    parts = [part for part in normalized.split("/") if part]
    return parts[-1] if parts else None

def _merge_qualifiers(base, added):
    qualifiers = dict(base or {})
    for key, value in added.items():
        if value != None and value != "":
            qualifiers[key] = value
    return qualifiers

def _common_qualifiers(
        *,
        sha256,
        integrity,
        download_url,
        file_name,
        repository_url,
        vcs_url):
    return {
        "checksum": _checksum_qualifier(sha256 = sha256, integrity = integrity),
        "download_url": download_url,
        "file_name": file_name,
        "repository_url": repository_url,
        "vcs_url": vcs_url,
    }

def _archive_attrs():
    attrs = dict(_COMMON_ATTRS)
    attrs.update({
        "add_prefix": attr.string(
            doc = "Destination directory relative to the repository directory, matching native http_archive.",
        ),
        "files": attr.string_keyed_label_dict(
            doc = "Map of relative paths to file labels symlinked into the repository last, overwriting existing files, matching native http_archive.",
        ),
        "patch_args": attr.string_list(
            doc = "Arguments passed to the patch tool, matching native http_archive.",
        ),
        "patch_cmds": attr.string_list(
            doc = "Shell commands run after patches are applied, matching native http_archive.",
        ),
        "patch_cmds_win": attr.string_list(
            doc = "Windows-specific patch_cmds; falls back to patch_cmds when empty, matching native http_archive.",
        ),
        "patch_tool": attr.string(
            doc = "Patch executable to use instead of the native patch implementation, matching native http_archive.",
        ),
        "remote_file_integrity": attr.string_dict(
            doc = "Map of remote_file_urls paths to integrity values, matching native http_archive.",
        ),
        "remote_file_urls": attr.string_list_dict(
            doc = "Map of relative paths to download URL lists, overlaid on the repository, matching native http_archive.",
        ),
        "remote_module_file_integrity": attr.string(
            doc = "For internal use only, matching native http_archive. Accepted but unused.",
        ),
        "remote_module_file_urls": attr.string_list(
            doc = "For internal use only, matching native http_archive. Accepted but unused.",
        ),
        "strip_components": attr.int(
            doc = "Number of leading path components to strip after extraction. Mutually exclusive with strip_prefix.",
        ),
        "strip_prefix": attr.string(
            doc = "Directory prefix to strip after extraction, matching native http_archive.",
        ),
        "workspace_file": attr.label(
            doc = "File to use as the repository WORKSPACE file. Mutually exclusive with workspace_file_content. Matches native http_archive in Bazel 8 and 9.",
        ),
        "workspace_file_content": attr.string(
            doc = "Content for the repository WORKSPACE file. Mutually exclusive with workspace_file. Matches native http_archive in Bazel 8 and 9.",
        ),
        "type": attr.string(
            doc = "Archive type override, matching native http_archive.",
        ),
    })
    return attrs

def _file_attrs():
    attrs = dict(_COMMON_ATTRS)
    attrs.update({
        "downloaded_file_path": attr.string(
            default = "downloaded",
            doc = "Output file path inside the generated repository, matching native http_file.",
        ),
        "executable": attr.bool(
            default = False,
            doc = "Whether the downloaded file should be executable.",
        ),
    })
    return attrs

def _build_purl_from_parts(parts):
    builder = purl.builder().type(parts["type"]).name(parts["name"])
    if parts.get("namespace"):
        builder = builder.namespace(parts["namespace"])
    if parts.get("version"):
        builder = builder.version(parts["version"])
    for key, value in sorted(parts["qualifiers"].items()):
        builder = builder.add_qualifier(key, value)
    if parts.get("subpath"):
        builder = builder.subpath(parts["subpath"])
    return builder.build()

def vers_version_conflict(version, qualifiers):
    """Returns an error message if the PURL has both a version and a vers qualifier, else None."""
    if version and "vers" in qualifiers:
        return "The 'vers' qualifier is mutually exclusive with the PURL version component (see https://github.com/package-url/purl-spec/blob/main/docs/specification/common-qualifiers.md); set either 'version' or a 'vers' qualifier, not both"
    return None

def build_metadata_purl(
        *,
        name,
        version,
        purl_pattern,
        sha256 = "",
        integrity = "",
        substitutions = {},
        download_url = None,
        file_name = None,
        repository_url = None,
        vcs_url = None,
        qualifiers = {}):
    """Builds a canonical PURL with common qualifiers added.

    Qualifiers follow https://github.com/package-url/purl-spec/blob/main/docs/common-qualifiers.md.
    """

    replacements = _replacement_values(
        name = name,
        version = version,
        sha256 = sha256,
        integrity = integrity,
        substitutions = substitutions,
    )
    rendered_purl = _replace_tokens(purl_pattern, replacements)
    parsed, err = purl.parse(rendered_purl)
    if err:
        fail("Invalid purl_pattern after expansion: {}".format(err))

    added_qualifiers = _common_qualifiers(
        sha256 = sha256,
        integrity = integrity,
        download_url = download_url,
        file_name = file_name,
        repository_url = repository_url,
        vcs_url = vcs_url,
    )
    added_qualifiers.update(qualifiers)
    parsed["qualifiers"] = _merge_qualifiers(parsed.get("qualifiers"), added_qualifiers)
    conflict = vers_version_conflict(parsed.get("version"), parsed["qualifiers"])
    if conflict:
        fail(conflict)

    return _build_purl_from_parts(parsed)

def _urls(ctx):
    replacements = _ctx_replacements(ctx)
    urls = []
    if ctx.attr.url:
        urls.append(ctx.attr.url)
    if ctx.attr.urls:
        urls.extend(ctx.attr.urls)
    elif ctx.attr.url_pattern and not ctx.attr.url:
        urls.append(ctx.attr.url_pattern)
    if not urls:
        fail("One of 'url', 'urls' or 'url_pattern' must be provided")
    return [_replace_tokens(url, replacements) for url in urls]

def _ctx_replacements(ctx):
    return _replacement_values(
        name = ctx.name,
        version = ctx.attr.version,
        sha256 = ctx.attr.sha256,
        integrity = ctx.attr.integrity,
        substitutions = ctx.attr.substitutions,
    )

def _ctx_integrity_values(ctx):
    return integrity_values(sha256 = ctx.attr.sha256, integrity = ctx.attr.integrity)

def _metadata_purl(ctx, urls):
    download_url = _first_url(urls)
    return build_metadata_purl(
        name = ctx.name,
        version = ctx.attr.version,
        purl_pattern = ctx.attr.purl_pattern,
        sha256 = ctx.attr.sha256,
        integrity = ctx.attr.integrity,
        substitutions = ctx.attr.substitutions,
        download_url = download_url,
        file_name = _basename(download_url),
        qualifiers = ctx.attr.qualifiers,
    )

def _metadata_load_fragment(integrity_values = []):
    load_fragment = """
load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
""".strip()
    if integrity_values:
        load_fragment = """
load("@package_metadata//attributes:integrity.bzl", "integrity")
""".strip() + "\n" + load_fragment
    return load_fragment

def _metadata_rule_fragment(metadata_purl, integrity_values = [], license = None):
    attributes = []
    fragments = []
    if integrity_values:
        attributes.append(":package_metadata_integrity")
        fragments.append("""
integrity(
    name = "package_metadata_integrity",
    values = {values},
    visibility = ["//visibility:public"],
)
""".format(values = repr(integrity_values)).strip() + "\n")
    if license:
        attributes.append(str(license))
    fragments.append("""
package_metadata(
    name = "package_metadata",{attributes}
    purl = {purl},
    visibility = ["//visibility:public"],
)
""".format(
        attributes = "\n    attributes = {},".format(repr(attributes)) if attributes else "",
        purl = repr(metadata_purl),
    ).strip() + "\n")
    return "\n".join(fragments)

def _metadata_repo_file_content():
    return """repo(default_package_metadata = ["//:package_metadata"])
"""

def build_file_with_package_metadata(metadata_purl, build_file_content = None, integrity_values = [], license = None):
    metadata_load = _metadata_load_fragment(integrity_values)
    metadata_rule = _metadata_rule_fragment(metadata_purl, integrity_values, license)
    if build_file_content:
        return metadata_load + "\n\n" + build_file_content + "\n\n" + metadata_rule
    return metadata_load + "\n\n" + metadata_rule + """
filegroup(
    name = "all_files",
    srcs = glob(["**/*"]),
    visibility = ["//visibility:public"],
)
"""

def build_http_file_file_package(downloaded_file_path):
    return """package(default_visibility = ["//visibility:public"])

exports_files([{downloaded_file_path}])

filegroup(
    name = "file",
    srcs = [{downloaded_file_path}],
)
""".format(downloaded_file_path = repr(downloaded_file_path))

def build_http_file_root_package(metadata_purl, downloaded_file_path, build_file_content = None, integrity_values = [], license = None):
    metadata_load = _metadata_load_fragment(integrity_values)
    metadata_rule = _metadata_rule_fragment(metadata_purl, integrity_values, license)
    if build_file_content:
        return metadata_load + "\n\n" + build_file_content + "\n\n" + metadata_rule

    aliases = [
        """alias(
    name = "file",
    actual = "//file",
)""",
    ]
    if "/" not in downloaded_file_path:
        aliases.append("""alias(
    name = {name},
    actual = "//file:{actual}",
)""".format(
            name = repr(downloaded_file_path),
            actual = downloaded_file_path,
        ))

    return (
        metadata_load +
        "\n\npackage(default_visibility = [\"//visibility:public\"])\n\n" +
        metadata_rule +
        "\n" +
        "\n".join(aliases) +
        "\n"
    )

def build_http_jar_root_package(metadata_purl, integrity_values = [], license = None):
    return (
        _metadata_load_fragment(integrity_values) +
        "\n\npackage(default_visibility = [\"//visibility:public\"])\n\n" +
        _metadata_rule_fragment(metadata_purl, integrity_values, license) +
        """
alias(
    name = "file",
    actual = "//jar:file",
)

alias(
    name = "jar",
    actual = "//jar",
)
"""
    )

def build_http_jar_package(downloaded_file_name, java_import_bzl):
    return """load({java_import_bzl}, "java_import")

package(default_visibility = ["//visibility:public"])

java_import(
    name = "jar",
    jars = [{file_name}],
)

filegroup(
    name = "file",
    srcs = [{file_name}],
)
""".format(
        java_import_bzl = repr(java_import_bzl),
        file_name = repr(downloaded_file_name),
    )

def repo_file_with_package_metadata():
    return _metadata_repo_file_content()

def _read_build_file_content(ctx):
    if ctx.attr.build_file and ctx.attr.build_file_content:
        fail("Only one of 'build_file' and 'build_file_content' may be specified")
    if ctx.attr.build_file:
        return ctx.read(ctx.attr.build_file)
    return ctx.attr.build_file_content if ctx.attr.build_file_content else None

def _write_workspace_file(ctx):
    if ctx.attr.workspace_file and ctx.attr.workspace_file_content:
        fail("Only one of 'workspace_file' and 'workspace_file_content' may be specified")
    if ctx.attr.workspace_file:
        ctx.file("WORKSPACE", ctx.read(ctx.attr.workspace_file))
    elif ctx.attr.workspace_file_content:
        ctx.file("WORKSPACE", ctx.attr.workspace_file_content)
    else:
        ctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(ctx.name))

def _apply_patches(ctx):
    patch(ctx)

def _validate_http_file_downloaded_file_path(ctx, downloaded_file_path):
    repo_root = ctx.path(".")
    forbidden_files = [
        repo_root,
        ctx.path("WORKSPACE"),
        ctx.path("BUILD"),
        ctx.path("BUILD.bazel"),
        ctx.path("file/BUILD"),
        ctx.path("file/BUILD.bazel"),
    ]
    download_path = ctx.path("file/" + downloaded_file_path)
    if download_path in forbidden_files or not str(download_path).startswith(str(repo_root)):
        fail("'{}' cannot be used as downloaded_file_path in http_file".format(ctx.attr.downloaded_file_path))

def _http_archive_impl(ctx):
    _verify_checksum_attrs(sha256 = ctx.attr.sha256, integrity = ctx.attr.integrity)
    if ctx.attr.strip_prefix and ctx.attr.strip_components:
        fail("Only one of 'strip_prefix' and 'strip_components' may be specified")
    urls = _urls(ctx)
    auth = get_auth(ctx, urls)
    canonical_id = ctx.attr.canonical_id or get_default_canonical_id(ctx, urls)
    strip_prefix = _replace_tokens(ctx.attr.strip_prefix, _ctx_replacements(ctx))
    ctx.download_and_extract(
        url = urls,
        output = ctx.attr.add_prefix,
        sha256 = ctx.attr.sha256,
        integrity = ctx.attr.integrity,
        stripPrefix = strip_prefix,
        type = ctx.attr.type,
        canonical_id = canonical_id,
        auth = auth,
        strip_components = ctx.attr.strip_components,
    )
    _write_workspace_file(ctx)
    download_remote_files(ctx)
    _apply_patches(ctx)
    metadata_purl = _metadata_purl(ctx, urls)
    ctx.file("BUILD.bazel", build_file_with_package_metadata(metadata_purl, _read_build_file_content(ctx), _ctx_integrity_values(ctx), ctx.attr.license))
    ctx.file("REPO.bazel", repo_file_with_package_metadata())
    symlink_files(ctx)

def _http_file_impl(ctx):
    _verify_checksum_attrs(sha256 = ctx.attr.sha256, integrity = ctx.attr.integrity)
    urls = _urls(ctx)
    downloaded_file_path = ctx.attr.downloaded_file_path
    _validate_http_file_downloaded_file_path(ctx, downloaded_file_path)
    ctx.download(
        url = urls,
        output = "file/" + downloaded_file_path,
        sha256 = ctx.attr.sha256,
        integrity = ctx.attr.integrity,
        executable = ctx.attr.executable,
        canonical_id = ctx.attr.canonical_id or get_default_canonical_id(ctx, urls),
        auth = get_auth(ctx, urls),
    )
    _apply_patches(ctx)
    metadata_purl = _metadata_purl(ctx, urls)
    build_file_content = _read_build_file_content(ctx)
    ctx.file("BUILD.bazel", build_http_file_root_package(metadata_purl, downloaded_file_path, build_file_content, _ctx_integrity_values(ctx), ctx.attr.license))
    ctx.file("file/BUILD", build_http_file_file_package(downloaded_file_path))
    ctx.file("REPO.bazel", repo_file_with_package_metadata())

def _http_jar_impl(ctx):
    _verify_checksum_attrs(sha256 = ctx.attr.sha256, integrity = ctx.attr.integrity)
    urls = _urls(ctx)
    for url in urls:
        if not url.split("?")[0].split("#")[0].endswith(".jar"):
            fail("'{}' must end in .jar".format(url))
    downloaded_file_name = ctx.attr.downloaded_file_name
    if "/" in downloaded_file_name or downloaded_file_name in ("", ".", "..", "BUILD", "BUILD.bazel"):
        fail("'{}' cannot be used as downloaded_file_name in http_jar".format(downloaded_file_name))
    ctx.download(
        url = urls,
        output = "jar/" + downloaded_file_name,
        sha256 = ctx.attr.sha256,
        integrity = ctx.attr.integrity,
        canonical_id = ctx.attr.canonical_id or get_default_canonical_id(ctx, urls),
        auth = get_auth(ctx, urls),
    )
    metadata_purl = _metadata_purl(ctx, urls)
    ctx.file("BUILD.bazel", build_http_jar_root_package(metadata_purl, _ctx_integrity_values(ctx), ctx.attr.license))
    ctx.file("jar/BUILD", build_http_jar_package(downloaded_file_name, str(Label("@rules_java//java:java_import.bzl"))))
    ctx.file("REPO.bazel", repo_file_with_package_metadata())

_COMMON_ATTRS = {
    "auth_patterns": attr.string_dict(
        doc = "Map of host names to custom authorization header patterns, matching native http_archive.",
    ),
    "canonical_id": attr.string(
        doc = "Cache key for the downloaded artifact, matching native http_archive.",
    ),
    "netrc": attr.string(
        doc = "Location of the .netrc file used for authentication, matching native http_archive.",
    ),
    "url": attr.string(
        doc = "A single download URL. Supports placeholders. Placed before urls.",
    ),
    "build_file": attr.label(
        allow_single_file = True,
        doc = "File to use as the generated repository BUILD file. The package_metadata target is appended. Mutually exclusive with build_file_content.",
    ),
    "build_file_content": attr.string(
        doc = "BUILD file content for the extracted repository. The package_metadata target is appended.",
    ),
    "integrity": attr.string(
        doc = "Artifact checksum in Subresource Integrity format. Mutually exclusive with sha256. Converted to the PURL checksum qualifier as '<algorithm>:<hex digest>'.",
    ),
    "sha256": attr.string(
        doc = "Artifact SHA-256 checksum as raw hex. Mutually exclusive with integrity. Added to the PURL checksum qualifier as 'sha256:<hex>'.",
    ),
    "substitutions": attr.string_dict(
        doc = "Additional literal replacements used by url_pattern, urls, strip_prefix, and purl_pattern. Keys are replaced as-is. Built-ins are {name}, {version}, {sha256}, and {integrity}.",
    ),
    "url_pattern": attr.string(
        doc = "Download URL pattern. Supports built-in placeholders such as {name}, {version}, {sha256}, and {integrity}.",
    ),
    "license": attr.label(
        doc = "Optional license target (a license() from @package_metadata//licenses) added to the attributes of the generated :package_metadata target. Resolved from the module using the rule, so it needs a bazel_dep on the repository defining it.",
    ),
    "patches": attr.label_list(
        allow_files = True,
        doc = "Patch files to apply after download/extraction, matching native http_archive.",
    ),
    "patch_strip": attr.int(
        default = 0,
        doc = "Number of leading path components to strip from local patches, matching native http_archive.",
    ),
    "purl_pattern": attr.string(
        mandatory = True,
        doc = "PURL pattern. Supports built-in placeholders such as {name}, {version}, {sha256}, and {integrity}. Common qualifiers are merged after parsing.",
    ),
    "qualifiers": attr.string_dict(
        doc = "Additional PURL qualifiers merged into the parsed PURL. They take precedence over the derived download_url (first URL) and file_name (its basename) qualifiers.",
    ),
    "remote_patches": attr.string_dict(
        doc = "Map of remote patch URL to integrity value, matching native http_archive.",
    ),
    "remote_patch_strip": attr.int(
        default = 0,
        doc = "Number of leading path components to strip from remote patches, matching native http_archive.",
    ),
    "urls": attr.string_list(
        doc = "Download URL patterns. Supports placeholders. Takes precedence over url_pattern.",
    ),
    "version": attr.string(
        doc = "Optional version used to expand url_pattern, urls, strip_prefix, and purl_pattern.",
    ),
}

http_archive = repository_rule(
    implementation = _http_archive_impl,
    attrs = _archive_attrs(),
    environ = [DEFAULT_CANONICAL_ID_ENV],
    doc = "Downloads and extracts an archive, then adds a package_metadata target for SBOM generation.",
)

http_file = repository_rule(
    implementation = _http_file_impl,
    attrs = _file_attrs(),
    environ = [DEFAULT_CANONICAL_ID_ENV],
    doc = "Downloads a file, then adds a package_metadata target for SBOM generation.",
)

_NON_JAR_ATTRS = [
    "build_file",
    "build_file_content",
    "patches",
    "patch_strip",
    "remote_patches",
    "remote_patch_strip",
]

def _jar_attrs():
    attrs = {k: v for k, v in _COMMON_ATTRS.items() if k not in _NON_JAR_ATTRS}
    attrs["downloaded_file_name"] = attr.string(
        default = "downloaded.jar",
        doc = "Filename assigned to the downloaded jar, matching native http_jar.",
    )
    return attrs

http_jar = repository_rule(
    implementation = _http_jar_impl,
    attrs = _jar_attrs(),
    environ = [DEFAULT_CANONICAL_ID_ENV],
    doc = "Downloads a jar and exposes it as java_import, then adds a package_metadata target for SBOM generation.",
)
