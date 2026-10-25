load("//private:failure_test.bzl", "failure_tests")
load("//private:http_test.bzl", "http_test")

exports_files(
    [
        "failure_test.bzl",
        "git.bzl",
        "http.bzl",
        "http_test.bzl",
    ],
    visibility = ["//visibility:public"],
)

http_test(
    name = "http_test",
)

failure_tests(name = "failure_tests")

filegroup(
    name = "srcs",
    srcs = [
        "BUILD",
        "failure_test.bzl",
        "git.bzl",
        "http.bzl",
        "http_test.bzl",
    ],
    visibility = ["//visibility:public"],
)
