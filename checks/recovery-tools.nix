{ pkgs }:
let
  inherit (pkgs) lib;
  tools = import ../lib/recovery-tools.nix { inherit pkgs; };
  postgresql = pkgs.postgresql_18;
  couchdb = pkgs.couchdb3;
  erlang = pkgs.beamMinimalPackages.erlang;
  otherErlang = pkgs.beamPackages.erlang;
  callback = pkgs.writeShellApplication {
    name = "recovery-owner-check";
    meta.mainProgram = "recovery-owner-check";
    text = "exit 0";
  };
  pgArgs = {
    inherit postgresql;
    dumpRelativePath = "native/pg-dump";
    database = "validation";
    check = callback;
  };
  couchArgs = {
    inherit couchdb erlang;
    sourceDirectory = "/tmp/primitives-source-couchdb";
    check = callback;
  };
  pg = tools.mkPostgresqlValidator pgArgs;
  couch = tools.mkCouchdbRecovery couchArgs;
  rejectsPg = args: !(builtins.tryEval (lib.getExe (tools.mkPostgresqlValidator args))).success;
  rejectsCouch =
    args: !(builtins.tryEval (lib.getExe (tools.mkCouchdbRecovery args).validate)).success;
  rejectsCouchComposition =
    args:
    lib.all (result: !(builtins.tryEval ((tools.mkCouchdbRecovery args).${result}.drvPath)).success) [
      "capture"
      "validate"
    ];
  executable =
    name: package:
    lib.isDerivation package
    && package.meta.mainProgram == name
    && lib.getExe package == "${package}/bin/${name}"
    && builtins.hasContext (lib.getExe package);
  rawCommand = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-check/bin/check";
  spoofedCommand = builtins.appendContext rawCommand (builtins.getContext "${callback}");
  invalidCallbacks = [
    rawCommand
    spoofedCommand
    (callback // { meta = { }; })
    (callback // { meta.mainProgram = ""; })
    (callback // { meta.mainProgram = 1; })
    (callback // { meta.mainProgram = null; })
    (callback // { meta.mainProgram = "../../../../tmp/mutable-callback"; })
  ];
  invalidComponentPackages = [
    (builtins.removeAttrs couchdb [ "override" ])
    (couchdb // { override = _: couchdb; })
    (couchdb // { override = builtins.removeAttrs couchdb.override [ "__functionArgs" ]; })
    (
      couchdb
      // {
        override = couchdb.override // {
          __functor = _: _: throw "native component replay check failure";
        };
      }
    )
    (
      couchdb
      // {
        override = couchdb.override // {
          __functor =
            _: _:
            assert false;
            couchdb;
        };
      }
    )
    (
      couchdb
      // {
        override = {
          __functor = 1;
          __functionArgs.beamMinimalPackages = false;
        };
      }
    )
  ];
  metadataCouchdb = couchdb.overrideAttrs (old: {
    meta = (old.meta or { }) // {
      description = "recovery native component metadata check";
    };
  });
  buildCouchdb = couchdb.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + "\n: # recovery native component build-attribute check\n";
  });
  componentCouchdb = couchdb.override {
    beamMinimalPackages = {
      erlang = otherErlang;
    };
  };
  componentBuildCouchdb = componentCouchdb.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + "\n: # recovery native component build-attribute check\n";
  });
  validComponentArgs = [
    (couchArgs // { couchdb = metadataCouchdb; })
    (couchArgs // { couchdb = buildCouchdb; })
    (
      couchArgs
      // {
        couchdb = componentCouchdb;
        erlang = otherErlang;
      }
    )
    (
      couchArgs
      // {
        couchdb = componentBuildCouchdb;
        erlang = otherErlang;
      }
    )
  ];
  # Explicit packages must suffice even when default DB attributes are unavailable.
  explicitTools = import ../lib/recovery-tools.nix {
    pkgs = pkgs // {
      postgresql_18 = throw "unexpected access to default PostgreSQL";
      couchdb3 = throw "unexpected access to default CouchDB";
    };
  };
  pgOnlyTools = import ../lib/recovery-tools.nix {
    pkgs = pkgs // {
      couchdb3 = throw "PostgreSQL factory accessed CouchDB";
      beamMinimalPackages = throw "PostgreSQL factory accessed Erlang";
    };
  };
  couchOnlyTools = import ../lib/recovery-tools.nix {
    pkgs = pkgs // {
      postgresql_18 = throw "CouchDB factory accessed PostgreSQL";
      nss_wrapper = throw "CouchDB factory accessed PostgreSQL NSS support";
      beamMinimalPackages = throw "CouchDB factory accessed default minimal Erlang";
      beamPackages = throw "CouchDB factory accessed default Erlang";
    };
  };
in
assert
  builtins.attrNames tools == [
    "mkCouchdbRecovery"
    "mkPostgresqlValidator"
  ];
assert
  builtins.attrNames couch == [
    "capture"
    "validate"
  ];
assert executable "validate-postgresql-recovery" pg;
assert executable "capture-couchdb-recovery" couch.capture;
assert executable "validate-couchdb-recovery" couch.validate;
assert (builtins.functionArgs tools.mkCouchdbRecovery).erlang == false;
assert erlang.version == otherErlang.version && erlang.drvPath != otherErlang.drvPath;
assert rejectsCouchComposition (couchArgs // { erlang = otherErlang; });
assert lib.all (erlang: rejectsCouchComposition (couchArgs // { inherit erlang; })) [
  rawCommand
  spoofedCommand
];
assert lib.all (
  couchdb: rejectsCouchComposition (couchArgs // { inherit couchdb; })
) invalidComponentPackages;
assert lib.all (
  args:
  let
    selected = tools.mkCouchdbRecovery args;
  in
  executable "capture-couchdb-recovery" selected.capture
  && executable "validate-couchdb-recovery" selected.validate
) validComponentArgs;
assert rejectsCouchComposition (
  couchArgs
  // {
    couchdb = buildCouchdb;
    erlang = otherErlang;
  }
);
assert rejectsCouchComposition (couchArgs // { couchdb = componentCouchdb; });
assert rejectsCouchComposition (couchArgs // { couchdb = componentBuildCouchdb; });
assert lib.all (check: rejectsPg (pgArgs // { inherit check; })) invalidCallbacks;
assert lib.all (check: rejectsCouch (couchArgs // { inherit check; })) invalidCallbacks;
assert lib.all (dumpRelativePath: rejectsPg (pgArgs // { inherit dumpRelativePath; })) [
  ""
  "/dump"
  "."
  ".."
  "../dump"
  "native/../dump"
  "native/./dump"
  "native//dump"
  "native/"
];
assert lib.all (sourceDirectory: rejectsCouch (couchArgs // { inherit sourceDirectory; })) [
  ""
  "relative/source"
];
assert rejectsPg (
  pgArgs
  // {
    postgresql = postgresql // {
      version = "17.7";
    };
  }
);
assert rejectsCouch (
  couchArgs
  // {
    couchdb = couchdb // {
      version = "3.5.3";
    };
  }
);
assert rejectsPg (pgArgs // { postgresql = "${postgresql}"; });
assert rejectsCouch (couchArgs // { couchdb = "${couchdb}"; });
assert executable "validate-postgresql-recovery" (explicitTools.mkPostgresqlValidator pgArgs);
assert executable "validate-couchdb-recovery" (explicitTools.mkCouchdbRecovery couchArgs).validate;
assert executable "validate-postgresql-recovery" (pgOnlyTools.mkPostgresqlValidator pgArgs);
assert executable "validate-couchdb-recovery" (couchOnlyTools.mkCouchdbRecovery couchArgs).validate;
assert executable "capture-couchdb-recovery" (couchOnlyTools.mkCouchdbRecovery couchArgs).capture;
true
