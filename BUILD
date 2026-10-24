package(
    default_visibility = ["//visibility:public"],
)

exports_files([
    "metadata_repo.bzl",
])

filegroup(
    name = "srcs",
    srcs = [
        "BUILD",
        "MODULE.bazel",
        "metadata_repo.bzl",
    ] + [
        "//private:srcs",
    ],
)
