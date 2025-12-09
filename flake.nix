{
  description = "NixOS (Pi 4) + ROS 2 Humble + prebuilt colcon workspace";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://ros.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
  };

  ##############################################################################
  # Inputs
  ##############################################################################
  inputs = {
    nix-ros-overlay.url = "github:lopsided98/nix-ros-overlay";
    nix-ros-overlay.flake = false;
    nixpkgs.url = "github:lopsided98/nixpkgs/nix-ros";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nix-ros-workspace.url = "github:hacker1024/nix-ros-workspace";
    nix-ros-workspace.flake = false;
    pyproject-nix.url = "github:pyproject-nix/pyproject.nix";
    pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";
    uv2nix.url = "github:pyproject-nix/uv2nix";
    uv2nix.inputs.pyproject-nix.follows = "pyproject-nix";
    uv2nix.inputs.nixpkgs.follows = "nixpkgs";
    pyproject-build-systems.url = "github:pyproject-nix/build-system-pkgs";
    pyproject-build-systems.inputs.pyproject-nix.follows = "pyproject-nix";
    pyproject-build-systems.inputs.uv2nix.follows = "uv2nix";
    pyproject-build-systems.inputs.nixpkgs.follows = "nixpkgs";
  };

  ##############################################################################
  # Outputs
  ##############################################################################
  outputs = { self, nixpkgs, nixos-hardware, nix-ros-workspace, nix-ros-overlay, pyproject-nix, uv2nix, pyproject-build-systems, ... }:
  let
    system = "aarch64-linux";

    # Overlay: pin python3 -> python312 (ROS Humble Python deps are happy here)
    pinPython312 = final: prev: {
      python3         = prev.python312;
      python3Packages = prev.python312Packages;
    };

    # ROS overlay setup from nix-ros-overlay (non-flake)
    rosBase = import nix-ros-overlay { inherit system; };

    rosOverlays =
      if builtins.isFunction rosBase then
        # Direct overlay function
        [ rosBase ]
      else if builtins.isList rosBase then
        # Already a list of overlay functions
        rosBase
      else if rosBase ? default && builtins.isFunction rosBase.default then
        # Attrset with a `default` overlay
        [ rosBase.default ]
      else if rosBase ? overlays && builtins.isList rosBase.overlays then
        # Attrset with `overlays = [ overlay1 overlay2 … ]`
        rosBase.overlays
      else if rosBase ? overlays
           && rosBase.overlays ? default
           && builtins.isFunction rosBase.overlays.default then
        # Attrset with `overlays.default` as the primary overlay
        [ rosBase.overlays.default ]
      else
        throw "nix-ros-overlay: unexpected structure; expected an overlay or list of overlays";

    rosWorkspaceOverlay = (import nix-ros-workspace { inherit system; }).overlay;
    
    pkgs = import nixpkgs {
      inherit system;
      overlays = rosOverlays ++ [ rosWorkspaceOverlay pinPython312 ];
    };

    lib     = pkgs.lib;
    rosPkgs = pkgs.rosPackages.humble;

    ############################################################################
    # Workspace discovery
    ############################################################################
    workspaceSrcPath =
      let
        # In robot repo: ./workspace/src
        # In dev repo: ../../shared/workspace/src
        path1 = ./workspace/src;
        path2 = ../../shared/workspace/src;
      in
        if builtins.pathExists path1 then path1
        else if builtins.pathExists path2 then path2
        else throw "workspace src not found at ${toString path1} or ${toString path2}";

    # Base Python set for pyproject-nix/uv2nix packages
    # pyproject-build-systems expects annotated-types to exist; ensure it is present.
    pythonForPyproject = pkgs.python3.override {
      packageOverrides = final: prev: {
        "annotated-types" =
          if prev ? "annotated-types" then prev."annotated-types" else prev.buildPythonPackage rec {
            pname = "annotated-types";
            version = "0.7.0";
            format = "pyproject";
            src = pkgs.fetchFromGitHub {
              owner = "annotated-types";
              repo = "annotated-types";
              tag = "v${version}";
              hash = "sha256-I1SPUKq2WIwEX5JmS3HrJvrpNrKDu30RWkBRDFE+k9A=";
            };
            nativeBuildInputs = [ prev.hatchling ];
            propagatedBuildInputs = lib.optionals (prev.pythonOlder "3.9") [ prev."typing-extensions" ];
          };
      };
    };

    pyProjectPythonBase = pkgs.callPackage pyproject-nix.build.packages {
      python = pythonForPyproject;
    };

    # Load webrtc workspace for uv2nix
    webrtcWorkspace = uv2nix.lib.workspace.loadWorkspace {
      workspaceRoot = workspaceSrcPath + "/webrtc";
    };

    # Robot Console static assets (expects dist/ already built in ./robot-console)
    robotConsoleSrc = builtins.path { path = ./robot-console; name = "robot-console-src"; };

    robotConsoleStatic = pkgs.stdenv.mkDerivation {
      pname = "robot-console";
      version = "0.1.0";
      src = robotConsoleSrc;
      dontUnpack = true;
      dontBuild = true;
      installPhase = ''
        set -euo pipefail
        mkdir -p $out/dist
        if [ -d "$src/dist" ]; then
          cp -rT "$src/dist" "$out/dist"
        else
          echo "robot-console dist/ not found; run npm install && npm run build in robot-console before building the image." >&2
          exit 1
        fi
      '';
    };

    # Robot API (FastAPI) packaged from ./robot-api
    robotApiSrc = pkgs.lib.cleanSource ./robot-api;
    robotApiPkg = pkgs.python3Packages.buildPythonPackage {
      pname = "robot-api";
      version = "0.1.0";
      src = robotApiSrc;
      format = "pyproject";
      propagatedBuildInputs = with pkgs.python3Packages; [
        fastapi
        uvicorn
        pydantic
        psutil
        websockets
      ];
      nativeBuildInputs = [
        pkgs.python3Packages.setuptools
        pkgs.python3Packages.wheel
      ];
    };

    ############################################################################
    # ROS 2 workspace (Humble)
    ############################################################################

    rosPackageDirs =
      let
        entries = builtins.readDir workspaceSrcPath;
        # Filter to directories and exclude webrtc (built separately)
        filtered = lib.filterAttrs (name: v: v == "directory" && name != "webrtc") entries;
      in builtins.trace
        ''polyflow-ros: found ROS dirs ${lib.concatStringsSep ", " (lib.attrNames filtered)} under ${workspaceSrcPath}''
        filtered;

    # Create overlays for each ROS package with pyproject.toml
    rosWorkspaceOverlays = lib.mapAttrsToList (name: _:
      let
        pkgPath = "${workspaceSrcPath}/${name}";
        hasPyproject = builtins.pathExists "${pkgPath}/pyproject.toml";
      in
        if hasPyproject then
          let
            workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = pkgPath; };
          in
            workspace.mkPyprojectOverlay { sourcePreference = "wheel"; }
        else
          (final: prev: {})  # empty overlay for packages without pyproject.toml
    ) rosPackageDirs;

    # Create Python set with all ROS workspace dependencies
    rosWorkspacePythonSet = pyProjectPythonBase.overrideScope (
      lib.composeManyExtensions (
        [ pyproject-build-systems.overlays.default ]
        ++ rosWorkspaceOverlays
        ++ [
          # Override odrive to add libusb dependency for native library
          (final: prev: lib.optionalAttrs (prev ? odrive) {
            odrive = prev.odrive.overrideAttrs (old: {
              buildInputs = (old.buildInputs or []) ++ [ pkgs.libusb1 ];
              nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoPatchelfHook ];
            });
          })
        ]
      )
    );

    # For each ROS package with a uv.lock, extract all dependencies (including transitive)
    rosUvDeps = lib.mapAttrs (name: _:
      let
        pkgPath = "${workspaceSrcPath}/${name}";
        hasUvLock = builtins.pathExists "${pkgPath}/uv.lock";
      in
        if hasUvLock then
          let
            # Read all package names from uv.lock
            lockfile = builtins.fromTOML (builtins.readFile "${pkgPath}/uv.lock");
            allPackages = lockfile.package or [];

            # Extract package names, excluding the package itself
            depNames = builtins.filter (n: n != name)
              (builtins.map (pkg: pkg.name) allPackages);

            # Safely try to get each dependency from the Python set
            tryGetPkg = pkgName:
              let
                result = builtins.tryEval (rosWorkspacePythonSet.${pkgName} or null);
              in
                if result.success && result.value != null then [result.value] else [];
          in
            builtins.concatMap tryGetPkg depNames
        else
          []
    ) rosPackageDirs;

    rosWorkspacePackages = lib.mapAttrs (name: _:
      let
        pkgPath = "${workspaceSrcPath}/${name}";
        hasPyproject = builtins.pathExists "${pkgPath}/pyproject.toml";
        # Read version from pyproject.toml if it exists, otherwise use default
        version = if hasPyproject then
          (builtins.fromTOML (builtins.readFile "${pkgPath}/pyproject.toml")).project.version
        else
          "0.0.1";
      in
      pkgs.python3Packages.buildPythonPackage {
      pname   = name;
      version = version;
      src     = pkgs.lib.cleanSource "${workspaceSrcPath}/${name}";

      format  = if hasPyproject then "pyproject" else "setuptools";

      dontUseCmakeConfigure = true;
      dontUseCmakeBuild     = true;
      dontUseCmakeInstall   = true;
      dontWrapPythonPrograms = true;

      nativeBuildInputs = if hasPyproject then [
        pkgs.python3Packages.pdm-backend
      ] else [
        pkgs.python3Packages.setuptools
      ];

      # Skip runtime dependency check for pyproject packages - deps are provided via propagatedBuildInputs
      nativeCheckInputs = if hasPyproject then [] else null;

      propagatedBuildInputs = with rosPkgs; [
        rclpy
        launch
        launch-ros
        ament-index-python
        composition-interfaces
      ] ++ [
        pkgs.python3Packages.pyyaml
      ] ++ (if rosUvDeps ? ${name} then rosUvDeps.${name} else []);

      postInstall = ''
        set -euo pipefail
        pkg="${name}"

        # 1: ament index registration
        mkdir -p $out/share/ament_index/resource_index/packages
        echo "$pkg" > $out/share/ament_index/resource_index/packages/$pkg

        # 2: package share (package.xml + launch)
        mkdir -p $out/share/$pkg/
        if [ -f ${workspaceSrcPath}/${name}/package.xml ]; then
          cp ${workspaceSrcPath}/${name}/package.xml $out/share/$pkg/
        fi
        if [ -f ${workspaceSrcPath}/${name}/$pkg.launch.py ]; then
          cp ${workspaceSrcPath}/${name}/$pkg.launch.py $out/share/$pkg/
        fi
        if [ -d ${workspaceSrcPath}/${name}/launch ]; then
          cp -r ${workspaceSrcPath}/${name}/launch $out/share/$pkg/
        fi

        # Resource marker(s)
        if [ -f ${workspaceSrcPath}/${name}/resource/$pkg ]; then
          install -Dm644 ${workspaceSrcPath}/${name}/resource/$pkg $out/share/$pkg/resource/$pkg
        elif [ -d ${workspaceSrcPath}/${name}/resource ]; then
          mkdir -p $out/share/$pkg/resource
          cp -r ${workspaceSrcPath}/${name}/resource/* $out/share/$pkg/resource/ || true
        fi

        # 3: libexec shim so launch_ros finds the executable under lib/$pkg/$pkg_node
        mkdir -p $out/lib/$pkg
        cat > "$out/lib/$pkg/''${pkg}_node" <<EOF
#!${pkgs.bash}/bin/bash
exec ${pkgs.python3}/bin/python3 -m ${name}.node "\$@"
EOF
        chmod +x $out/lib/$pkg/''${pkg}_node
      '';
    }) rosPackageDirs;

    rosWorkspaceBase = pkgs.buildEnv {
      name = "polyflow-ros";
      paths = lib.attrValues rosWorkspacePackages;
    };

    # workspace.launch.py - optional for base repo, required for robot repos
    # Generated by polyflow-studio and placed in workspace/src/
    workspaceLaunchPath = ./workspace/src/workspace.launch.py;
    hasWorkspaceLaunch = builtins.pathExists workspaceLaunchPath;

    rosWorkspace = if hasWorkspaceLaunch then
      pkgs.runCommand "polyflow-ros-with-launch" {} ''
        # Create output directory structure
        mkdir -p $out

        # Copy everything from base workspace EXCEPT share directory
        if [ -d "${rosWorkspaceBase}" ]; then
          for item in ${rosWorkspaceBase}/*; do
            itemname=$(basename "$item")
            if [ "$itemname" != "share" ]; then
              cp -r "$item" "$out/"
            fi
          done
        fi

        # Create fresh share directory and copy contents
        mkdir -p $out/share
        if [ -d "${rosWorkspaceBase}/share" ]; then
          cp -r ${rosWorkspaceBase}/share/* $out/share/ 2>/dev/null || true
        fi

        # Add workspace.launch.py
        cp ${workspaceLaunchPath} $out/share/workspace.launch.py
      ''
    else
      rosWorkspaceBase;

    # Python (ROS toolchain) + helpers
    rosPy = rosPkgs.python3;
    # Keep ament_python builds on the ROS Python set; do not fall back to the repo-pinned 3.12 toolchain.
    rosPyPkgs = rosPkgs.python3Packages or (rosPy.pkgs or (throw "rosPkgs.python3Packages unavailable"));
    py = pkgs.python3;
    pyPkgs = py.pkgs or pkgs.python3Packages;
    sp = py.sitePackages;

    # Build a fixed osrf-pycommon (PEP 517), reusing nixpkgs' source
    osrfSrc = pkgs.python3Packages."osrf-pycommon".src;

    osrfFixed = pyPkgs.buildPythonPackage {
      pname        = "osrf-pycommon";
      version      = "2.0.2";
      src          = osrfSrc;
      pyproject    = true;
      build-system = [ py.pkgs.setuptools py.pkgs.wheel ];
      doCheck      = false;
    };

    # Minimal Python environment for running webrtc + ROS Python bits
    pyEnv = py.withPackages (ps: [
      ps.pyyaml
      ps.empy
      ps.catkin-pkg
      osrfFixed
    ]);

    ############################################################################
    # WebRTC (Python) package for robot
    ############################################################################
    webrtcSrc = pkgs.lib.cleanSourceWith {
      src = builtins.path { path = workspaceSrcPath + "/webrtc"; name = "webrtc-src"; };
      filter = path: type:
        # include typical project files; drop bytecode and VCS junk
        !(pkgs.lib.hasSuffix ".pyc" path)
        && !(pkgs.lib.hasInfix "/__pycache__/" path)
        && !(pkgs.lib.hasInfix "/.git/" path);
    };

    # Read version from pyproject.toml
    webrtcPyproject = builtins.fromTOML (builtins.readFile (workspaceSrcPath + "/webrtc/pyproject.toml"));
    webrtcVersion = webrtcPyproject.project.version;

    # Create Python set with webrtc dependencies from uv2nix (no global attrNames scanning)
    webrtcOverlay = webrtcWorkspace.mkPyprojectOverlay {
      sourcePreference = "wheel";
    };

    webrtcPythonSet = pyProjectPythonBase.overrideScope (
      lib.composeManyExtensions [
        pyproject-build-systems.overlays.default
        webrtcOverlay
        # Override odrive to add libusb dependency for native library
        (final: prev: lib.optionalAttrs (prev ? odrive) {
          odrive = prev.odrive.overrideAttrs (old: {
            buildInputs = (old.buildInputs or []) ++ [ pkgs.libusb1 ];
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.autoPatchelfHook ];
          });
        })
      ]
    );

    # Extract all uv2nix dependencies from webrtc/uv.lock (includes transitive deps)
    webrtcUvDeps =
      let
        # Read all package names from uv.lock
        lockfile = builtins.fromTOML (builtins.readFile (workspaceSrcPath + "/webrtc/uv.lock"));
        allPackages = lockfile.package or [];

        # Extract package names, excluding the webrtc package itself
        depNames = builtins.filter (n: n != "webrtc")
          (builtins.map (pkg: pkg.name) allPackages);

        # Safely try to get each dependency from the Python set
        tryGetPkg = name:
          let
            result = builtins.tryEval (webrtcPythonSet.${name} or null);
          in
            if result.success && result.value != null then [result.value] else [];
      in
        builtins.concatMap tryGetPkg depNames;

    webrtcPkg = webrtcPythonSet.webrtc.overrideAttrs (old: {
      pname   = "webrtc";
      version = webrtcVersion;
      src     = webrtcSrc;

      # ROS runtime deps + python extras + uv2nix deps
      propagatedBuildInputs =
        webrtcUvDeps
        ++ (with rosPkgs; [
          rclpy
          launch
          launch-ros
          ament-index-python
          composition-interfaces
        ])
        ++ [ pkgs.python3Packages.pyyaml ];

      postInstall = (old.postInstall or "") + ''
        # 1: ament index registration
        mkdir -p $out/share/ament_index/resource_index/packages
        echo webrtc > $out/share/ament_index/resource_index/packages/webrtc

        # 2: package share (package.xml + launch)
        mkdir -p $out/share/webrtc/
        cp ${webrtcSrc}/package.xml $out/share/webrtc/
        cp ${webrtcSrc}/webrtc.launch.py $out/share/webrtc

        # Resource marker, if present
        if [ -f ${webrtcSrc}/resource/webrtc ]; then
          install -Dm644 ${webrtcSrc}/resource/webrtc $out/share/webrtc/resource/webrtc
        fi

        # 3: libexec shim so launch_ros finds the executable under lib/webrtc/webrtc_node
        mkdir -p $out/lib/webrtc
        cat > $out/lib/webrtc/webrtc_node <<'EOF'
#!${pkgs.bash}/bin/bash
exec ${pkgs.python3}/bin/python3 -m webrtc.node "$@"
EOF
        chmod +x $out/lib/webrtc/webrtc_node
      '';
    });

    # Python environment with webrtc and all its dependencies (including uv2nix deps)
    # Use buildEnv to combine packages from different Python sets (uv2nix + ROS)
    webrtcPythonEnv = pkgs.buildEnv {
      name = "webrtc-python-env";
      paths = [ webrtcPkg ] ++ (webrtcPkg.propagatedBuildInputs or []);
      pathsToLink = [ "/lib" ];
    };

    # Python environment with rosWorkspace and all its dependencies
    # Use buildEnv to combine packages from different Python sets (uv2nix + ROS)
    rosWorkspacePythonEnv = pkgs.buildEnv {
      name = "ros-workspace-python-env";
      paths = [ rosWorkspace ] ++ (rosWorkspace.propagatedBuildInputs or []);
      pathsToLink = [ "/lib" ];
    };
  in
  {
    # Export packages
    packages.${system} = {
      webrtcPkg        = webrtcPkg;
      robotConsoleStatic = robotConsoleStatic;
      robotApiPkg      = robotApiPkg;
      rosWorkspace     = rosWorkspace;
      webrtcPythonEnv  = webrtcPythonEnv;
      rosWorkspacePythonEnv = rosWorkspacePythonEnv;
    };

    # Full NixOS config for Pi 4 (sd-image)
    nixosConfigurations.rpi4 = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit webrtcPkg pyEnv robotConsoleStatic robotApiPkg rosWorkspace webrtcPythonEnv rosWorkspacePythonEnv;
      };
      modules = [
        ({ ... }: {
          nixpkgs.overlays =
            rosOverlays ++ [ rosWorkspaceOverlay pinPython312 ];
        })
        nixos-hardware.nixosModules.raspberry-pi-4
        ./configuration.nix
      ];
    };
  };
}
