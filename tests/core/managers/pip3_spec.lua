local mock = require "luassert.mock"
local spy = require "luassert.spy"
local match = require "luassert.match"

local pip3 = require "nvim-lsp-installer.core.managers.pip3"
local Optional = require "nvim-lsp-installer.core.optional"
local Result = require "nvim-lsp-installer.core.result"
local settings = require "nvim-lsp-installer.settings"
local spawn = require "nvim-lsp-installer.core.spawn"

describe("pip3 manager", function()
    ---@type InstallContext
    local ctx
    before_each(function()
        ctx = InstallContextGenerator {
            spawn = mock.new {
                python3 = mockx.returns {},
            },
        }
    end)

    it("normalizes pip3 packages", function()
        local normalize = pip3.normalize_package
        assert.equal("python-lsp-server", normalize "python-lsp-server[all]")
        assert.equal("python-lsp-server", normalize "python-lsp-server[]")
        assert.equal("python-lsp-server", normalize "python-lsp-server[[]]")
    end)

    it(
        "should create venv and call pip3 install",
        async_test(function()
            ctx.requested_version = Optional.of "42.13.37"
            pip3.packages { "main-package", "supporting-package", "supporting-package2" }(ctx)
            assert.spy(ctx.promote_cwd).was_called(1)
            assert.spy(ctx.spawn.python3).was_called(2)
            assert.spy(ctx.spawn.python3).was_called_with {
                "-m",
                "venv",
                "venv",
            }
            assert.spy(ctx.spawn.python3).was_called_with(match.tbl_containing {
                "-m",
                "pip",
                "install",
                "-U",
                match.table(),
                match.tbl_containing {
                    "main-package==42.13.37",
                    "supporting-package",
                    "supporting-package2",
                },
                env = match.is_table(),
            })
        end)
    )

    it(
        "should exhaust python3 executable candidates if all fail",
        async_test(function()
            vim.g.python3_host_prog = "/my/python3"
            ctx.spawn = mock.new {
                python3 = mockx.throws(),
                python = mockx.throws(),
                [vim.g.python3_host_prog] = mockx.throws(),
            }
            local err = assert.has_error(function()
                pip3.packages { "package" }(ctx)
            end)
            vim.g.python3_host_prog = nil

            assert.equals("Unable to create python3 venv environment.", err)
            assert.spy(ctx.spawn["/my/python3"]).was_called(1)
            assert.spy(ctx.spawn.python3).was_called(1)
            assert.spy(ctx.spawn.python).was_called(1)
        end)
    )

    it(
        "should not exhaust python3 executable if one succeeds",
        async_test(function()
            vim.g.python3_host_prog = "/my/python3"
            ctx.spawn = mock.new {
                python3 = mockx.throws(),
                python = mockx.throws(),
                [vim.g.python3_host_prog] = mockx.returns {},
            }
            pip3.packages { "package" }(ctx)
            vim.g.python3_host_prog = nil
            assert.spy(ctx.spawn.python3).was_called(0)
            assert.spy(ctx.spawn.python).was_called(0)
            assert.spy(ctx.spawn["/my/python3"]).was_called()
        end)
    )

    it(
        "should use install_args from settings",
        async_test(function()
            settings.set {
                pip = {
                    install_args = { "--proxy", "http://localhost:8080" },
                },
            }
            pip3.packages { "package" }(ctx)
            settings.set(settings._DEFAULT_SETTINGS)
            assert.spy(ctx.spawn.python3).was_called_with(match.tbl_containing {
                "-m",
                "pip",
                "install",
                "-U",
                match.tbl_containing { "--proxy", "http://localhost:8080" },
                match.tbl_containing { "package" },
                env = match.is_table(),
            })
        end)
    )

    it(
        "should provide receipt information",
        async_test(function()
            ctx.requested_version = Optional.of "42.13.37"
            pip3.packages { "main-package", "supporting-package", "supporting-package2" }(ctx)
            assert.equals(
                vim.inspect {
                    type = "pip3",
                    package = "main-package",
                },
                vim.inspect(ctx.receipt.primary_source)
            )
            assert.equals(
                vim.inspect {
                    {
                        type = "pip3",
                        package = "supporting-package",
                    },
                    {
                        type = "pip3",
                        package = "supporting-package2",
                    },
                },
                vim.inspect(ctx.receipt.secondary_sources)
            )
        end)
    )
end)

describe("pip3 version check", function()
    it(
        "should return current version",
        async_test(function()
            spawn.python = spy.new(function()
                return Result.success {
                    stdout = [[
    [{"name": "astroid", "version": "2.9.3"}, {"name": "mccabe", "version": "0.6.1"}, {"name": "python-lsp-server", "version": "1.3.0", "latest_version": "1.4.0", "latest_filetype": "wheel"}, {"name": "wrapt", "version": "1.13.3", "latest_version": "1.14.0", "latest_filetype": "wheel"}]
                    ]],
                }
            end)

            local result = pip3.get_installed_primary_package_version(
                mock.new {
                    primary_source = mock.new {
                        type = "pip3",
                        package = "python-lsp-server",
                    },
                },
                "/tmp/install/dir"
            )

            assert.spy(spawn.python).was_called(1)
            assert.spy(spawn.python).was_called_with(match.tbl_containing {
                "-m",
                "pip",
                "list",
                "--format=json",
                cwd = "/tmp/install/dir",
                env = match.table(),
            })
            assert.is_true(result:is_success())
            assert.equals("1.3.0", result:get_or_nil())

            spawn.python = nil
        end)
    )

    it(
        "should return outdated primary package",
        async_test(function()
            spawn.python = spy.new(function()
                return Result.success {
                    stdout = [[
[{"name": "astroid", "version": "2.9.3", "latest_version": "2.11.0", "latest_filetype": "wheel"}, {"name": "mccabe", "version": "0.6.1", "latest_version": "0.7.0", "latest_filetype": "wheel"}, {"name": "python-lsp-server", "version": "1.3.0", "latest_version": "1.4.0", "latest_filetype": "wheel"}, {"name": "wrapt", "version": "1.13.3", "latest_version": "1.14.0", "latest_filetype": "wheel"}]
                ]],
                }
            end)

            local result = pip3.check_outdated_primary_package(
                mock.new {
                    primary_source = mock.new {
                        type = "pip3",
                        package = "python-lsp-server",
                    },
                },
                "/tmp/install/dir"
            )

            assert.spy(spawn.python).was_called(1)
            assert.spy(spawn.python).was_called_with(match.tbl_containing {
                "-m",
                "pip",
                "list",
                "--outdated",
                "--format=json",
                cwd = "/tmp/install/dir",
                env = match.table(),
            })
            assert.is_true(result:is_success())
            assert.equals(
                vim.inspect {
                    name = "python-lsp-server",
                    current_version = "1.3.0",
                    latest_version = "1.4.0",
                },
                vim.inspect(result:get_or_nil())
            )

            spawn.python = nil
        end)
    )

    it(
        "should return failure if primary package is not outdated",
        async_test(function()
            spawn.python = spy.new(function()
                return Result.success {
                    stdout = "[]",
                }
            end)

            local result = pip3.check_outdated_primary_package(
                mock.new {
                    primary_source = mock.new {
                        type = "pip3",
                        package = "python-lsp-server",
                    },
                },
                "/tmp/install/dir"
            )

            assert.is_true(result:is_failure())
            assert.equals("Primary package is not outdated.", result:err_or_nil())
            spawn.python = nil
        end)
    )
end)
