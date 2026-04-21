uap_core_repo := "https://github.com/ua-parser/uap-core.git"

_default:
    just --list

uap-core:
    @test -d uap-core || git clone {{ uap_core_repo }} uap-core

update-uap-core: uap-core
    cd uap-core && git pull

@generate: uap-core
    gleam run -m generate_uaparser
    gleam format

@test:
    gleam test --target erlang
    gleam test --target javascript

@bench:
    gleam run -m benchmark --target erlang
    gleam run -m benchmark --target javascript

@lint:
    gleam run -m glinter

@choire:
    gleam run -m choire ..

@docs:
    gleam docs build

@docs-open: docs
    open build/dev/docs/uaparser_gleam/index.html
