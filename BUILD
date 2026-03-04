load("//:sh_executable.bzl", "sh_executable")

package(default_visibility = ["//visibility:public"])

sh_executable(
    name = "ios_test_runner",
    src = "bin/ios_test_runner",
    data = glob(["lib/*.sh"]),
)

sh_executable(
    name = "simulator_creator",
    src = "bin/simulator_creator",
)

filegroup(
    name = "for_bazel_tests",
    testonly = 1,
    srcs = glob(["**/*"]),
)
