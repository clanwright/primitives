{ pkgs }:
let
  inherit (pkgs) lib;
  executablePackage =
    package:
    lib.isDerivation package
    && builtins.isString (package.meta.mainProgram or null)
    && package.meta.mainProgram != "";
  application =
    name: script: dependencies: variables:
    let
      runtime = pkgs.writeShellApplication {
        name = "${name}-runtime";
        meta.mainProgram = "${name}-runtime";
        inheritPath = false;
        runtimeInputs = dependencies ++ [
          pkgs.coreutils
          pkgs.findutils
        ];
        runtimeEnv = variables;
        text = builtins.readFile ./recovery/common.sh + "\n" + builtins.readFile script;
      };
    in
    pkgs.writeShellApplication {
      inherit name;
      meta.mainProgram = name;
      inheritPath = false;
      # Clear inherited environment before the native writer sets PATH and vars.
      text = ''
        exec ${lib.getExe' pkgs.coreutils "env"} -i ${lib.getExe runtime} "$@"
      '';
    };
in
{
  # The caller supplies a native custom-format archive from the source package.
  mkPostgresqlValidator =
    {
      postgresql,
      dumpRelativePath,
      database,
      check,
    }:
    assert lib.isDerivation postgresql;
    assert
      builtins.isString (postgresql.version or null)
      && postgresql.version != ""
      && lib.versions.major postgresql.version == "18";
    assert executablePackage check;
    assert dumpRelativePath != "" && !(lib.hasPrefix "/" dumpRelativePath);
    assert
      !(builtins.any (part: part == ".." || part == "." || part == "") (
        lib.splitString "/" dumpRelativePath
      ));
    application "validate-postgresql-recovery" ./recovery/postgresql-validate.sh
      [ postgresql pkgs.gnugrep ]
      {
        DUMP_RELATIVE_PATH = dumpRelativePath;
        PGDATABASE = database;
        CHECK_COMMAND = lib.getExe check;
        NSS_LIBRARY = "${lib.getLib pkgs.nss_wrapper}/lib/libnss_wrapper.so";
      };
  mkCouchdbRecovery =
    {
      couchdb,
      erlang,
      sourceDirectory,
      check,
      nodeName ? "couchdb@localhost",
    }:
    assert lib.isDerivation couchdb;
    assert (couchdb.version or "") == "3.5.2";
    assert lib.assertMsg (lib.isDerivation erlang)
      "mkCouchdbRecovery: erlang must be a derivation package";
    let
      override = couchdb.override or null;
      hasOverrideMetadata =
        builtins.isAttrs override
        && builtins.isFunction (override.__functor or null)
        && builtins.isAttrs (override.__functionArgs or null);
      supportsComponent =
        hasOverrideMetadata && lib.isFunction override && (lib.functionArgs override ? beamMinimalPackages);
      replayed = override { beamMinimalPackages = { inherit erlang; }; };
      componentReplay = builtins.tryEval (
        replayed.drvPath == couchdb.drvPath && replayed.outPath == couchdb.outPath
      );
    in
    assert lib.assertMsg supportsComponent
      "mkCouchdbRecovery: couchdb lacks supported native beamMinimalPackages override metadata";
    assert lib.assertMsg componentReplay.success
      "mkCouchdbRecovery: native CouchDB component replay failed";
    assert lib.assertMsg componentReplay.value
      "mkCouchdbRecovery: erlang does not reproduce the supplied couchdb derivation and output";
    assert executablePackage check;
    assert lib.hasPrefix "/" sourceDirectory;
    assert builtins.match "[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+" nodeName != null;
    {
      capture = application "capture-couchdb-recovery" ./recovery/couchdb-capture.sh [ pkgs.jq ] {
        SOURCE_DIRECTORY = sourceDirectory;
        NODE_NAME = nodeName;
      };
      validate =
        application "validate-couchdb-recovery" ./recovery/couchdb-validate.sh
          [ couchdb erlang pkgs.curl pkgs.jq pkgs.gnused ]
          ({
            NODE_NAME = nodeName;
            CHECK_COMMAND = lib.getExe check;
            COUCHDB_DEFAULT_INI = "${couchdb}/etc/default.ini";
            CA_CERTIFICATES = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          });
    };
}
