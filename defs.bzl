"""Public API for HTTP repository rules that emit package metadata."""

load("//private:git.bzl", _git_repository = "git_repository")
load("//private:http.bzl", _http_archive = "http_archive", _http_file = "http_file", _http_jar = "http_jar")

http_archive = _http_archive
http_file = _http_file
http_jar = _http_jar
git_repository = _git_repository
