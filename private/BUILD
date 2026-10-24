load("//private:http_test.bzl", "http_test")

exports_files(
    [
        "git.bzl",
        "http.bzl",
        "http_test.bzl",
    ],
    visibility = ["//visibility:public"],
)

http_test(
    name = "http_test",
)

filegroup(
    name = "srcs",
    srcs = [
        "BUILD",
        "git.bzl",
        "http.bzl",
        "http_test.bzl",
    ],
    visibility = ["//visibility:public"],
)
