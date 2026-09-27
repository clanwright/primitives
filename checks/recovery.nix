{ nixpkgs, clan-core }:
let
  inherit (nixpkgs) lib;
  module = import ../modules/recovery.nix;
  command = "${nixpkgs.legacyPackages.x86_64-linux.coreutils}/bin/true";
  unit = {
    contractVersion = 1;
    formatVersion = "v1.archive-2";
    stateRefs = [ "alpha" ];
    captureCommand = command;
    validateCommand = command;
  };
  stateModule = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              assertion = lib.mkOption { type = lib.types.bool; };
              message = lib.mkOption { type = lib.types.str; };
            };
          }
        );
        default = [ ];
      };
      clan.core.state = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.folders = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          }
        );
        default = { };
      };
    };
  };
  evaluate =
    units: states:
    lib.evalModules {
      modules = [
        module
        stateModule
        {
          clanwright.recovery.units = units;
          clan.core.state = states;
        }
      ];
    };
  failures =
    units: states:
    map (assertion: assertion.message) (
      builtins.filter (assertion: !assertion.assertion) (evaluate units states).config.assertions
    );
  valid =
    units: states:
    let
      configured = (evaluate units states).config.clanwright.recovery.units;
      required = map (entry: [
        entry.contractVersion
        entry.formatVersion
        entry.stateRefs
        entry.captureCommand
        entry.validateCommand
      ]) (builtins.attrValues configured);
    in
    (builtins.tryEval (builtins.deepSeq required true)).success;
  invalid = units: states: !(valid units states);
  states = {
    alpha.folders = [ "/var/lib/alpha" ];
    beta.folders = [ "/var/lib/beta" ];
    duplicate.folders = [ "/var/lib/alpha" ];
    alias.folders = [ "/var/lib//alpha/" ];
    parentAlias.folders = [ "/var/lib/beta/../alpha" ];
    dotAlias.folders = [ "/var/lib/./alpha" ];
    relative.folders = [ "var/lib/alpha" ];
    child.folders = [ "/var/lib/alpha/child" ];
  };
  replace = fields: unit // fields;
  without = key: builtins.removeAttrs unit [ key ];
  standalone =
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        module
        {
          boot.isContainer = true;
          system.stateVersion = "26.11";
        }
      ];
    }).config;
  clan = clan-core.lib.clan {
    self.inputs.self.clan = clan.config;
    specialArgs.clan-core = clan-core;
    directory = ./.;
    imports = [
      {
        machines.fixture = {
          imports = [ module ];
          nixpkgs.hostPlatform = "x86_64-linux";
          boot.isContainer = true;
          system.stateVersion = "26.11";
          clan.core.state.alpha.folders = [ "/var/lib/alpha" ];
          clan.core.state.beta.folders = [ "/var/lib/beta" ];
          clanwright.recovery.units = {
            first = unit;
            second = replace {
              stateRefs = [ "beta" ];
            };
          };
        };
        inventory.meta.name = "recovery-fixture";
        inventory.machines.fixture = { };
      }
    ];
  };
  host = clan.config.nixosConfigurations.fixture.config;
  hostFailures = map (a: a.message) (builtins.filter (a: !a.assertion) host.assertions);
in
assert standalone.clanwright.recovery.units == { };
assert !(builtins.hasAttr "clan" standalone);
assert valid {
  first = unit;
  second = replace { stateRefs = [ "beta" ]; };
} states;
assert
  failures {
    first = unit;
    second = replace { stateRefs = [ "beta" ]; };
  } states == [ ];
assert hostFailures == [ ];
assert
  builtins.attrNames host.clanwright.recovery.units == [
    "first"
    "second"
  ];
assert invalid { first = without "contractVersion"; } states;
assert invalid { first = replace { contractVersion = 2; }; } states;
assert invalid { first = without "formatVersion"; } states;
assert invalid { first = replace { formatVersion = ""; }; } states;
assert invalid { first = replace { formatVersion = "v/2"; }; } states;
assert invalid {
  first = replace { formatVersion = lib.concatStrings (lib.replicate 65 "a"); };
} states;
assert invalid { first = without "stateRefs"; } states;
assert invalid { first = replace { stateRefs = [ ]; }; } states;
assert invalid { first = without "captureCommand"; } states;
assert invalid { first = without "validateCommand"; } states;
assert invalid {
  first = replace { captureCommand = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-tool/bin/true"; };
} states;
assert invalid {
  first = replace { captureCommand = "${nixpkgs.legacyPackages.x86_64-linux.coreutils}"; };
} states;
assert invalid {
  first = replace {
    validateCommand = "${nixpkgs.legacyPackages.x86_64-linux.coreutils}/bin/../true";
  };
} states;
assert invalid { first = replace { unknown = true; }; } states;
assert failures { "Bad-ID" = unit; } states != [ ];
assert failures { first = replace { stateRefs = [ "missing" ]; }; } states != [ ];
assert
  failures {
    first = replace {
      stateRefs = [
        "alpha"
        "alpha"
      ];
    };
  } states != [ ];
assert
  failures {
    first = replace {
      stateRefs = [
        "alpha"
        "duplicate"
      ];
    };
  } states != [ ];
assert
  failures {
    first = unit;
    second = unit;
  } states == [ ];
assert
  failures {
    first = unit;
    second = replace { captureCommand = "${nixpkgs.legacyPackages.x86_64-linux.coreutils}/bin/false"; };
  } states != [ ];
assert
  failures {
    first = replace {
      stateRefs = [
        "alpha"
        "beta"
      ];
    };
    second = unit;
  } states != [ ];
assert
  failures {
    first = unit;
    second = replace { stateRefs = [ "duplicate" ]; };
  } states != [ ];
assert
  failures {
    first = unit;
    second = replace { stateRefs = [ "child" ]; };
  } states != [ ];
assert
  failures {
    first = unit;
    second = replace { stateRefs = [ "alias" ]; };
  } states != [ ];
assert failures { first = replace { stateRefs = [ "parentAlias" ]; }; } states != [ ];
assert failures { first = replace { stateRefs = [ "dotAlias" ]; }; } states != [ ];
assert failures { first = replace { stateRefs = [ "relative" ]; }; } states != [ ];
true
