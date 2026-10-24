"""Test helpers."""

load("@bazel_skylib//rules:diff_test.bzl", "diff_test")
load("@rules_shell//shell:sh_test.bzl", "sh_test")

def metadata_test(name, repo, expect, integrity = True):
    """Asserts on the package_metadata (and integrity) files of an external repo.

    Args:
      name: test name.
      repo: apparent repo name, for example "zlib".
      expect: strings that must appear; prefix with "!" for strings that must not.
      integrity: whether the repo has a package_metadata_integrity target.
    """
    data = ["@%s//:package_metadata" % repo]
    if integrity:
        data.append("@%s//:package_metadata_integrity" % repo)
    sh_test(
        name = name,
        srcs = ["assert_contains.sh"],
        args = ["$(rlocationpaths %s)" % d for d in data] + ["--"] + expect,
        data = data,
    )

def tree_listing(name, srcs):
    """Lists the files of `srcs` with their cksum, relative to their repo root."""
    native.genrule(
        name = name,
        srcs = srcs,
        outs = [name + ".txt"],
        cmd = """for f in $(SRCS); do
  echo "$$(echo $$f | sed -E 's#^external/[^/]+/##') $$(cksum < $$f)"
done | sort > $@""",
    )

def compat_test(name, ours, native_repo, target = "srcs"):
    """Checks that our repo rule extracts exactly what the native rule extracts."""
    tree_listing(name + "_ours", ["@%s//:%s" % (ours, target)])
    tree_listing(name + "_native", ["@%s//:%s" % (native_repo, target)])
    diff_test(
        name = name,
        file1 = ":" + name + "_ours",
        file2 = ":" + name + "_native",
    )
