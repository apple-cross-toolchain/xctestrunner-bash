"""Minimal shell executable rule without external dependencies."""

def _sh_executable_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = output,
        target_file = ctx.file.src,
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.file.src] + ctx.files.data)
    return [DefaultInfo(executable = output, runfiles = runfiles)]

sh_executable = rule(
    implementation = _sh_executable_impl,
    attrs = {
        "src": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "data": attr.label_list(
            allow_files = True,
        ),
    },
    executable = True,
)
