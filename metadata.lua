-- metadata.lua
-- mise backend plugin: truebrew (Homebrew bottles without Homebrew)
-- Docs: https://mise.jdx.dev/backend-plugin-development.html

PLUGIN = { -- luacheck: ignore
    name = "truebrew",
    version = "0.1.0",
    description = "Install Homebrew formulae as mise tools, without Homebrew",
    author = "mise-truebrew",
    homepage = "https://github.com/mise-plugins/mise-truebrew",
    license = "MIT",
    notes = {
        "macOS (arm64/x86_64) and Linux (arm64/x86_64); Windows is not supported by Homebrew bottles",
        "Uses formulae.brew.sh JSON API + GHCR bottles, verifies sha256, relocates placeholders",
    },
}
