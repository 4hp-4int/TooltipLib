--[[
    TooltipLib — PZ Test Kit configuration

    The hook/contract tests in tests/ drive the REAL Hook.lua (and friends)
    against a mocked ISUI layer, so they need `UIView/UIMock`. That mock lives
    in the kit's uiview harness mod, which is declared as a test-only
    dependency here rather than vendored into this repo.

    These tests used to live in pz-test-kit/uiview/tests/ purely because that
    was where UIMock resolved — they are TooltipLib's regression suite and
    belong with TooltipLib. uiview keeps only the tests that are genuinely its
    own (scene rendering + golden display lists), and still declares
    ../../PZ-TooltipLib as a dependency so those scenes can build real panels.
]]

return {
    dependencies = {
        -- headless ISUI mock (UIView/UIMock, UIView/Recorder)
        "../pz-test-kit/uiview",
    },
}
