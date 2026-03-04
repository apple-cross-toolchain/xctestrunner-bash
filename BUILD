load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

package(default_visibility = ["//visibility:public"])

sh_binary(
    name = "ios_test_runner",
    srcs = ["bin/ios_test_runner"],
    data = [
        "lib/bundle.sh",
        "lib/common.sh",
        "lib/constants.sh",
        "lib/executor.sh",
        "lib/plist_json.sh",
        "lib/session.sh",
        "lib/simulator.sh",
        "lib/xcode.sh",
        "lib/xcresult.sh",
    ],
)

sh_binary(
    name = "simulator_creator",
    srcs = ["bin/simulator_creator"],
)

filegroup(
    name = "for_bazel_tests",
    testonly = 1,
    srcs = [
        "bin/ios_test_runner",
        "bin/simulator_creator",
        "lib/bundle.sh",
        "lib/common.sh",
        "lib/constants.sh",
        "lib/executor.sh",
        "lib/plist_json.sh",
        "lib/session.sh",
        "lib/simulator.sh",
        "lib/xcode.sh",
        "lib/xcresult.sh",
    ],
)
