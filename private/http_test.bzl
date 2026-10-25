"""Tests for enhanced HTTP helper functions."""

load("//private:git.bzl", "build_vcs_url")
load(
    "//private:http.bzl",
    "build_file_with_package_metadata",
    "build_http_file_file_package",
    "build_http_file_root_package",
    "build_http_jar_package",
    "build_http_jar_root_package",
    "effective_integrity",
    "integrities_error",
    "integrity_error",
    "integrity_values",
    "build_metadata_purl",
    "repo_file_with_package_metadata",
    "vers_version_conflict",
)

def _test_impl(ctx):
    failures = []

    actual = build_metadata_purl(
        name = "zlib",
        version = "1.3.1",
        purl_pattern = "pkg:generic/zlib@{version}?repository_url=https://zlib.net",
        sha256 = "38ef96b8d0a7d57784f7f444b587d7c4f9c931b6d4f3f3d8e8f4b4e4adf3f8b8",
        download_url = "https://zlib.net/zlib-1.3.1.tar.gz",
        file_name = "zlib-1.3.1.tar.gz",
        vcs_url = "git+https://github.com/madler/zlib.git",
    )
    expected = "pkg:generic/zlib@1.3.1?checksum=sha256:38ef96b8d0a7d57784f7f444b587d7c4f9c931b6d4f3f3d8e8f4b4e4adf3f8b8&download_url=https:%2F%2Fzlib.net%2Fzlib-1.3.1.tar.gz&file_name=zlib-1.3.1.tar.gz&repository_url=https:%2F%2Fzlib.net&vcs_url=git%2Bhttps:%2F%2Fgithub.com%2Fmadler%2Fzlib.git"
    if actual != expected:
        failures.append("expected {}, got {}".format(expected, actual))

    actual = build_metadata_purl(
        name = "tool",
        version = "2.1.0",
        purl_pattern = "pkg:github/{owner}/{repo}@{version}",
        sha256 = "abcdef",
        substitutions = {
            "{owner}": "example",
            "{repo}": "tool",
        },
    )
    expected = "pkg:github/example/tool@2.1.0?checksum=sha256:abcdef"
    if actual != expected:
        failures.append("expected {}, got {}".format(expected, actual))

    actual = build_metadata_purl(
        name = "empty",
        version = "0",
        integrity = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=",
        purl_pattern = "pkg:generic/empty@{version}",
    )
    expected = "pkg:generic/empty@0?checksum=sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    if actual != expected:
        failures.append("expected {}, got {}".format(expected, actual))

    # sha256 and integrity (SRI) must yield the same lowercase hex checksum qualifier.
    empty_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    for kwargs, expected_checksum in [
        ({"sha256": empty_sha256}, "sha256:" + empty_sha256),
        ({"sha256": empty_sha256.upper()}, "sha256:" + empty_sha256),
        ({"integrity": "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="}, "sha256:" + empty_sha256),
        ({"integrity": "SHA256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="}, "sha256:" + empty_sha256),
        (
            {"integrity": "sha384-OLBgp1GsljhM2TJ+sbHjaiH9txEUvgdDTAzHv2P24donTt6/529l+9Ua0vFImLlb"},
            "sha384:38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b",
        ),
        (
            {"integrity": "sha512-z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg=="},
            "sha512:cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
        ),
    ]:
        actual = build_metadata_purl(
            name = "checksum",
            version = "1",
            purl_pattern = "pkg:generic/checksum@{version}",
            **kwargs
        )
        expected = "pkg:generic/checksum@1?checksum=" + expected_checksum
        if actual != expected:
            failures.append("expected {}, got {}".format(expected, actual))

    root = build_http_jar_root_package("pkg:maven/com.google.guava/guava@33.0.0")
    for fragment in [
        'package_metadata(\n    name = "package_metadata",\n    purl = "pkg:maven/com.google.guava/guava@33.0.0",',
        'alias(\n    name = "jar",\n    actual = "//jar",\n)',
        'alias(\n    name = "file",\n    actual = "//jar:file",\n)',
    ]:
        if fragment not in root:
            failures.append("expected http_jar root BUILD to contain {}, got {}".format(fragment, root))

    jar_build = build_http_jar_package("guava.jar", "@rules_java//java:java_import.bzl")
    for fragment in [
        'load("@rules_java//java:java_import.bzl", "java_import")',
        'java_import(\n    name = "jar",\n    jars = ["guava.jar"],\n)',
        'filegroup(\n    name = "file",\n    srcs = ["guava.jar"],\n)',
    ]:
        if fragment not in jar_build:
            failures.append("expected http_jar BUILD to contain {}, got {}".format(fragment, jar_build))

    for kwargs, expected_values in [
        ({"sha256": "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"}, ["sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="]),
        ({"sha256": "00"}, ["sha256-AA=="]),
        ({"sha256": "0001"}, ["sha256-AAE="]),
        ({"sha256": "000102"}, ["sha256-AAEC"]),
        ({"integrity": "sha512-AAAA"}, ["sha512-AAAA"]),
    ]:
        actual = integrity_values(sha256 = kwargs.get("sha256", ""), integrity = kwargs.get("integrity", ""))
        if actual != expected_values:
            failures.append("expected integrity values {}, got {}".format(expected_values, actual))

    for integrity, valid in [
        ("", True),
        ("sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", True),
        ("sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU= sha512-AAAA", False),
    ]:
        if (integrity_error(integrity) == None) != valid:
            failures.append("unexpected integrity_error result for '{}'".format(integrity))

    sri_sha256 = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
    sri_sha384 = "sha384-OLBgp1GsljhM2TJ+sbHjaiH9txEUvgdDTAzHv2P24donTt6/529l+9Ua0vFImLlb"
    for integrities, valid in [
        ([], True),
        ([sri_sha256, sri_sha384], True),
        (["md5-AAAA", sri_sha256], True),
        ([sri_sha256, "sha256-AAAA"], False),
        (["md5-AAAA"], False),
        (["noalgorithm"], False),
        ([sri_sha256 + " " + sri_sha384], False),
    ]:
        if (integrities_error(integrities) == None) != valid:
            failures.append("unexpected integrities_error result for {}".format(integrities))

    for integrity, integrities, expected in [
        ("", [], ""),
        (sri_sha256, [], sri_sha256),
        ("", ["md5-AAAA", sri_sha384, sri_sha256], sri_sha384),
    ]:
        actual = effective_integrity(integrity, integrities)
        if actual != expected:
            failures.append("expected effective integrity {}, got {}".format(expected, actual))

    actual = integrity_values(sha256 = "", integrity = "", integrities = [sri_sha256, sri_sha384])
    if actual != [sri_sha256, sri_sha384]:
        failures.append("expected integrities passthrough, got {}".format(actual))

    # Multiple checksums are comma-separated; the purl builder percent-encodes the comma.
    actual = build_metadata_purl(
        name = "multi",
        version = "1",
        purl_pattern = "pkg:generic/multi@{version}?integrity={integrity}",
        integrities = ["md5-AAAA", sri_sha384, sri_sha256],
    )
    expected = "pkg:generic/multi@1?checksum=md5:000000%2Csha384:38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b%2Csha256:" + empty_sha256 + "&integrity=" + sri_sha384.replace("+", "%2B").replace("/", "%2F")
    if actual != expected:
        failures.append("expected {}, got {}".format(expected, actual))

    values = ["sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="]
    for name, generated in [
        ("archive", build_file_with_package_metadata("pkg:generic/a", None, values)),
        ("archive with build file", build_file_with_package_metadata("pkg:generic/a", "# custom", values)),
        ("file", build_http_file_root_package("pkg:generic/a", "a.txt", None, values)),
        ("jar", build_http_jar_root_package("pkg:generic/a", values)),
    ]:
        for fragment in [
            'load("@package_metadata//attributes:integrity.bzl", "integrity")',
            'integrity(\n    name = "package_metadata_integrity",\n    values = ["sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="],\n    visibility = ["//visibility:public"],\n)',
            'attributes = [":package_metadata_integrity"]',
        ]:
            if fragment not in generated:
                failures.append("expected {} BUILD to contain {}, got {}".format(name, fragment, generated))

    for remote, expected_vcs_url in [
        ("https://github.com/a/b.git", "git+https://github.com/a/b.git@abc"),
        ("https://user:token@github.com/a/b.git", "git+https://github.com/a/b.git@abc"),
        ("git+https://github.com/a/b.git", "git+https://github.com/a/b.git@abc"),
        ("ssh://git@github.com/a/b.git", "git+ssh://git@github.com/a/b.git@abc"),
        ("git@github.com:a/b.git", "git+ssh://git@github.com/a/b.git@abc"),
        ("git://github.com/a/b.git", "git+git://github.com/a/b.git@abc"),
        ("file:///tmp/repo", "git+file:///tmp/repo@abc"),
        ("/tmp/repo", "git+file:///tmp/repo@abc"),
    ]:
        actual = build_vcs_url(remote, "abc")
        if actual != expected_vcs_url:
            failures.append("expected vcs_url {}, got {}".format(expected_vcs_url, actual))

    actual = build_metadata_purl(
        name = "dep",
        version = "",
        purl_pattern = "pkg:github/a/b@abc",
        vcs_url = build_vcs_url("https://github.com/a/b.git", "abc"),
    )
    expected = "pkg:github/a/b@abc?vcs_url=git%2Bhttps:%2F%2Fgithub.com%2Fa%2Fb.git%40abc"
    if actual != expected:
        failures.append("expected {}, got {}".format(expected, actual))

    for version, qualifiers, expect_conflict in [
        ("1.0.0", {"vers": "vers:semver/>=1.0.0"}, True),
        ("", {"vers": "vers:semver/>=1.0.0"}, False),
        ("1.0.0", {"arch": "any"}, False),
        ("", {}, False),
    ]:
        conflict = vers_version_conflict(version, qualifiers)
        if bool(conflict) != expect_conflict:
            failures.append("vers_version_conflict({}, {}) returned {}".format(version, qualifiers, conflict))

    repo_file = repo_file_with_package_metadata()
    expected_repo_file = """repo(default_package_metadata = ["//:package_metadata"])
"""
    if repo_file != expected_repo_file:
        failures.append("expected REPO.bazel {}, got {}".format(expected_repo_file, repo_file))

    licensed_build_file = build_file_with_package_metadata(
        "pkg:generic/zlib@1.3.1",
        license = "@@//:zlib_license",
    )
    for fragment in [
        'attributes = ["@@//:zlib_license"],',
    ]:
        if fragment not in licensed_build_file:
            failures.append("expected licensed BUILD to contain {}, got {}".format(fragment, licensed_build_file))

    licensed_integrity_build_file = build_file_with_package_metadata(
        "pkg:generic/zlib@1.3.1",
        integrity_values = ["sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="],
        license = "@@//:zlib_license",
    )
    expected_attributes = 'attributes = [":package_metadata_integrity", "@@//:zlib_license"],'
    if expected_attributes not in licensed_integrity_build_file:
        failures.append("expected {}, got {}".format(expected_attributes, licensed_integrity_build_file))

    build_file = build_file_with_package_metadata(
        "pkg:generic/zlib@1.3.1",
        """load("//tools:defs.bzl", "tool")

tool(name = "tool")""",
    )
    expected_build_file = """load("@package_metadata//rules:package_metadata.bzl", "package_metadata")

load("//tools:defs.bzl", "tool")

tool(name = "tool")

package_metadata(
    name = "package_metadata",
    purl = "pkg:generic/zlib@1.3.1",
    visibility = ["//visibility:public"],
)
"""
    if build_file != expected_build_file:
        failures.append("expected BUILD.bazel {}, got {}".format(expected_build_file, build_file))

    file_package = build_http_file_file_package("bin/tool")
    expected_file_package = """package(default_visibility = ["//visibility:public"])

exports_files(["bin/tool"])

filegroup(
    name = "file",
    srcs = ["bin/tool"],
)
"""
    if file_package != expected_file_package:
        failures.append("expected file/BUILD {}, got {}".format(expected_file_package, file_package))

    root_package = build_http_file_root_package("pkg:github/example/tool@1.0.0", "tool")
    expected_root_package = """load("@package_metadata//rules:package_metadata.bzl", "package_metadata")

package(default_visibility = ["//visibility:public"])

package_metadata(
    name = "package_metadata",
    purl = "pkg:github/example/tool@1.0.0",
    visibility = ["//visibility:public"],
)

alias(
    name = "file",
    actual = "//file",
)
alias(
    name = "tool",
    actual = "//file:tool",
)
"""
    if root_package != expected_root_package:
        failures.append("expected root BUILD.bazel {}, got {}".format(expected_root_package, root_package))

    script = ctx.actions.declare_file(ctx.attr.name + ".sh")
    ctx.actions.write(
        output = script,
        content = "#!/usr/bin/env bash\n{body}\n".format(
            body = "exit 0" if not failures else "echo '{}' && exit 1".format(json.encode(failures)),
        ),
        is_executable = True,
    )
    return [DefaultInfo(executable = script, files = depset([script]))]

http_test = rule(
    implementation = _test_impl,
    test = True,
)
