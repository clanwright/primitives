{ config, lib, ... }:
let
  units = config.clanwright.recovery.units;
  unitNames = builtins.attrNames units;
  states = config.clan.core.state or { };
  validCommand =
    command:
    let
      parts = lib.splitString "/" command;
    in
    builtins.getContext command != { }
    && builtins.match "/nix/store/[a-z0-9]{32}-[^/]+(/[^/]+)+" command != null
    && !(builtins.any (part: part == "." || part == "..") parts);
  groups = map (name: {
    inherit name;
    unit = units.${name};
  }) unitNames;
  pairs = lib.concatMap (
    left:
    map (right: {
      inherit left right;
    }) (builtins.filter (right: right.name > left.name) groups)
  ) groups;
  sameRefs = a: b: builtins.sort builtins.lessThan a == builtins.sort builtins.lessThan b;
  overlaps = a: b: builtins.any (ref: builtins.elem ref b) a;
  unitFolders =
    refs:
    lib.concatMap (ref: if builtins.hasAttr ref states then states.${ref}.folders or [ ] else [ ]) refs;
  validFolder =
    path:
    lib.hasPrefix "/" path
    && !(builtins.any (part: part == "." || part == "..") (lib.splitString "/" path));
  normalizeFolder =
    path:
    "/" + lib.concatStringsSep "/" (builtins.filter (part: part != "") (lib.splitString "/" path));
  folderOverlaps =
    a: b:
    builtins.any (
      left:
      builtins.any (
        right:
        let
          leftPath = normalizeFolder left;
          rightPath = normalizeFolder right;
        in
        leftPath == rightPath
        || leftPath == "/"
        || rightPath == "/"
        || lib.hasPrefix "${leftPath}/" rightPath
        || lib.hasPrefix "${rightPath}/" leftPath
      ) b
    ) a;
in
{
  options.clanwright.recovery.units = lib.mkOption {
    default = { };
    description = "Declarative capture contract for registered Clan state. This module creates no runtime units.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          contractVersion = lib.mkOption {
            type = lib.types.enum [ 1 ];
            description = "Required recovery contract version.";
          };
          formatVersion = lib.mkOption {
            type = lib.types.addCheck lib.types.nonEmptyStr (
              value: builtins.stringLength value <= 64 && builtins.match "[A-Za-z0-9_.-]+" value != null
            );
            description = "Required, nonempty archive format identifier (at most 64 ASCII characters).";
          };
          stateRefs = lib.mkOption {
            type = lib.types.addCheck (lib.types.listOf lib.types.nonEmptyStr) (refs: refs != [ ]);
            default = throw "Recovery unit stateRefs is required.";
            description = "Required, nonempty list of existing Clan state registration names.";
          };
          captureCommand = lib.mkOption {
            type = lib.types.addCheck lib.types.str validCommand;
            description = "Required immutable store executable path for capture; retain its Nix string context.";
          };
          validateCommand = lib.mkOption {
            type = lib.types.addCheck lib.types.str validCommand;
            description = "Required immutable store executable path for archive validation; retain its Nix string context.";
          };
        };
      }
    );
  };

  config = lib.mkIf (units != { }) {
    assertions =
      (map (name: {
        assertion = builtins.match "[a-z][a-z0-9-]*" name != null;
        message = "Recovery unit '${name}' must start with a lowercase letter and contain only lowercase letters, digits, or hyphens.";
      }) unitNames)
      ++ (lib.concatMap (
        entry:
        let
          refs = entry.unit.stateRefs;
          rawFolders = unitFolders refs;
          folders = map normalizeFolder rawFolders;
        in
        [
          {
            assertion = builtins.length refs == builtins.length (lib.unique refs);
            message = "Recovery unit '${entry.name}' must not repeat a stateRef.";
          }
          {
            assertion = builtins.all (ref: builtins.hasAttr ref states) refs;
            message = "Recovery unit '${entry.name}' references a missing clan.core.state registration.";
          }
          {
            assertion = builtins.all validFolder rawFolders;
            message = "Recovery unit '${entry.name}' requires absolute state folders without . or .. path segments.";
          }
          {
            assertion = builtins.length folders == builtins.length (lib.unique folders);
            message = "Recovery unit '${entry.name}' must not register the same state folder twice.";
          }
        ]
      ) groups)
      ++ (map (
        pair:
        let
          a = pair.left.unit;
          b = pair.right.unit;
        in
        {
          assertion =
            !(
              overlaps a.stateRefs b.stateRefs
              || folderOverlaps (unitFolders a.stateRefs) (unitFolders b.stateRefs)
            )
            || (sameRefs a.stateRefs b.stateRefs && a.captureCommand == b.captureCommand);
          message = "Recovery units '${pair.left.name}' and '${pair.right.name}' overlap stateRefs or state folders without identical stateRef groups and captureCommand.";
        }
      ) pairs);
  };
}
