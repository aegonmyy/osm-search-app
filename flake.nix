{
  description = "osm_search — 'OSM Search' Basecamp app. A standalone consumer of the osm SDK that lets the user fetch verified OSM region data from Logos Storage by its on-chain CID and build a local search index (via the osm_search_core Rust core), then answers geocode / reverse-geocode queries offline.";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    nixpkgs.follows = "logos-module-builder/nixpkgs";
    # The SDK module this app depends on (metadata.json dependencies: ["osm"]).
    # The osm core is NOT modified by osm_search; it stays the unchanged SDK.
    logos-osm.url = "github:aegonmyy/logos-osm";
    logos-osm.inputs.logos-module-builder.follows = "logos-module-builder";
    # The standalone search core module this app depends on
    # (metadata.json dependencies: ["osm_search_core"]). It is a Rust cdylib
    # (interface: cdylib, codegen.rust) that owns the SQLite FTS5+rtree
    # indexes + a background build job system and declares no module
    # dependencies — the app passes catalog/cache_dir/pbf as invoke_op args.
    osm-search-core.url = "github:aegonmyy/osm-search-core";
    osm-search-core.inputs.logos-module-builder.follows = "logos-module-builder";
    # logos-rust-sdk is pulled so the search core's flake input follows it
    # through this app's resolution (keeps the SDK pin consistent).
    osm-search-core.inputs.logos-rust-sdk.follows = "logos-rust-sdk";
    logos-rust-sdk.url = "github:logos-co/logos-rust-sdk/49dbb0768a9a18cfaf264cc3ecfa55cca2630157";
  };

  outputs = inputs@{ logos-module-builder, logos-osm, osm-search-core, ... }:
    logos-module-builder.lib.mkLogosQmlModule {
      src = ./.;
      configFile = ./metadata.json;
      # `osm` and `osm_search_core` are the names metadata.json declares as
      # dependencies; the builder resolves their interfaces from these inputs.
      # osm is the unchanged SDK core; osm_search_core is the standalone Rust
      # search core built from aegonmyy/osm-search-core.
      flakeInputs = inputs // {
        osm = logos-osm;
        osm_search_core = osm-search-core;
      };
    };
}
