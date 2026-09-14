--- hooks/backend_list_tools.lua
--- Finite catalog for `mise search` / completion. Package-manager backends
--- must NOT enumerate the whole ecosystem here (see backend_search_tools).

function PLUGIN:BackendListTools(ctx)
    return {
        tools = {
            { name = "jq", description = "Lightweight and flexible command-line JSON processor" },
            { name = "ripgrep", description = "Search tool like grep and the silver searcher" },
            { name = "wget", description = "Internet file retriever" },
            { name = "curl", description = "Get a file from an HTTP, HTTPS or FTP server" },
            { name = "bat", description = "Clone of cat with syntax highlighting" },
            { name = "fd", description = "Simple, fast and user-friendly alternative to find" },
            { name = "eza", description = "Modern replacement for ls" },
            { name = "fzf", description = "Command-line fuzzy finder" },
            { name = "gh", description = "GitHub's official command line tool" },
            { name = "git", description = "Distributed revision control system" },
            { name = "openssl@3", description = "Cryptography and SSL/TLS toolkit" },
            { name = "sqlite", description = "Command-line interface for SQLite" },
            { name = "python@3.13", description = "Interpreted, interactive, object-oriented programming language" },
            { name = "node", description = "Platform built on V8 to build network applications" },
            { name = "ffmpeg", description = "Play, record, convert, and stream audio and video" },
            { name = "imagemagick", description = "Tools and libraries to manipulate images" },
            { name = "cmake", description = "Cross-platform make" },
            { name = "pkgconf", description = "Package compiler and linker metadata toolkit" },
            { name = "coreutils", description = "GNU File, Shell, and Text utilities" },
            { name = "grep", description = "GNU grep, egrep and fgrep" },
        },
    }
end
