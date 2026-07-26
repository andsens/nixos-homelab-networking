{ inputs, self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  # See https://github.com/NixOS/nixpkgs/blob/597283ad8aa0b331c788e97c4c262d58877074ef/nixos/modules/services/networking/unifi.nix
  ccfg = config.homelab.cluster;
  cfg = config.homelab.services.unifi;
  container-utils = inputs.homelab.packages.${pkgs.stdenv.hostPlatform.system}.container-utils;
  unifiOSImgName =
    builtins.head
      (builtins.head (
        builtins.fromJSON (
          builtins.readFile (
            pkgs.stdenvNoCC.mkDerivation {
              name = "unifi-os-img-manifest.json";
              src = cfg.package;
              dontUnpack = true;
              installPhase = ''tar -xzOf "$src" manifest.json >"$out"'';
            }
          )
        )
      )).RepoTags;
  unifiOSUIDs = {
    ucs-update = 974;
    ucs-agent = 975;
    unifi-credential-server = 976;
    uid = 991;
    unifi = 997;
    unifi-core = 998;
    ulp-go = 999;
  };
  portsByName = {
    # https://help.ui.com/hc/en-us/articles/218506997-Required-Ports-Reference
    # DNS lookups for Guest Portal redirection and updates (also required for Remote Management)
    dns-tcp = {
      containerPort = 53;
      protocol = "TCP";
    };
    dns-udp = {
      containerPort = 53;
      protocol = "UDP";
    };
    # STUN for device adoption and communication (also required for Remote Management)
    stun = {
      containerPort = 3478;
      protocol = "UDP";
    };
    # Traffic Flow logging for UXGs adopted on L2 or L3 networks.
    flow-log = 5671;
    # Device and application communication. Some U6 APs may have this port open on device for UP-Sense communication.
    u6-ap-comms = 8080;
    # Application GUI/API (on UniFi Console)
    web = 8443;
    # Hotspot portal redirection (HTTP)
    hotspot-http-1 = 8880;
    hotspot-http-2 = 8881;
    hotspot-http-3 = 8882;
    # Hotspot portal redirection (HTTPS)
    hotspot-https = 8843;
    # Secure Portal for Hotspot
    hotspot-portal = 8444;
    # UniFi mobile speed test
    mobile-speed = 6789;
    # Local database communication
    db = 27117;
    # Device packet capture and support file downloads
    pcap = 28082;
    # Device discovery during adoption
    discover = {
      containerPort = 10001;
      protocol = "UDP";
    };
    # Client fingerprinting information
    client-fp = {
      containerPort = 10101;
      protocol = "UDP";
    };
    # L2 discovery (“Make application discoverable on L2 network”)
    l2-discovery = {
      containerPort = 1900;
      protocol = "UDP";
    };
    # # Remote syslog capture
    syslog = {
      containerPort = 5514;
      protocol = "UDP";
    };
    # Remote syslog capture
    ssh-tcp = {
      containerPort = 22;
      protocol = "TCP";
    };
    ssh-udp = {
      containerPort = 22;
      protocol = "TCP";
    };
    # Application GUI/API access via web browser (also required for Remote Management)
    web-2 = 443;
    # Site Magic SD-WAN tunnel port range (if all ports are in use, it will then try another free port above 20000, then try above/below this range).
    sd-wan = {
      containerPort = 20100; # - 22100
      protocol = "UDP";
    };
  };
  volumeMountsByPath = {
    "/tls" = "tls";
    "/tmp" = "tmp";
    "/var/log/nginx" = {
      name = "data";
      subPath = "logs/nginx";
    };
    "/var/log/mongodb" = {
      name = "data";
      subPath = "logs/mongodb";
    };
    "/var/log/rabitmq" = {
      name = "data";
      subPath = "logs/rabitmq";
    };
    "/data" = {
      name = "data";
      subPath = "data";
    };
    "/srv" = {
      name = "data";
      subPath = "srv";
    };
    "/var/lib/unifi" = {
      name = "data";
      subPath = "unifi";
    };
    "/var/lib/mongodb" = {
      name = "data";
      subPath = "mongodb";
    };
  };
  volumesByName = {
    tls.secret.secretName = "unifi-tls";
  };
in
{
  options.homelab.services.unifi = {
    enable = lib.mkEnableOption "Unifi Controller";
    debug = lib.mkEnableOption "debug mode";
    package = lib.mkOption {
      type = lib.types.package;
      description = "The extracted UniFi OS Server OCI archive.";
      default = pkgs.callPackage ../../packages/unifi-os {
        url = "https://fw-download.ubnt.com/data/unifi-os-server/f5e2-linux-x64-5.1.21-a400c9c6-8328-4634-b223-ebfcf742720a.21-x64";
        version = "5.1.21";
        sha256 = "sha256-d+P+rBWVd5QC3Yf/jSDWb6o5yHtXJkb4b/AAZxEmJEU=";
      };
    };
  };
  imports = [
    inputs.homelab.nixosModules.postgresql
  ];
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.homelab.services.postgresql.enable;
        message = "Unifi depends on the PostgreSQL service. Enable with `homelab.postgresql.enable=true`";
      }
    ];
    homelab.services.postgresql = {
      databases.unifi.backup.enable = lib.mkDefault true;
    };
    services.k3s.images = [ cfg.package ];
    homelab.cluster.backup.volumes.unifi.unifi = [ "/var/lib/unifi/data" ];
    kubetree.resources.unifi = {
      certificate = {
        apiVersion = "cert-manager.io/v1";
        kind = "Certificate";
        metadata = {
          namespace = "unifi";
          name = "unifi";
          labels."app.kubernetes.io/name" = "unifi";
        };
        spec = {
          secretName = "unifi-tls";
          commonName = "unifi.${ccfg.domain}";
          dnsNames = [ "unifi.${ccfg.domain}" ];
          issuerRef = {
            group = "cert-manager.io";
            kind = "ClusterIssuer";
            name = config.kubetree.service-macros.acmeProvider;
          };
        };
      };
      external-service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = {
          namespace = "unifi";
          name = "unifi-external";
          labels."app.kubernetes.io/name" = "unifi";
          annotations."external-dns.alpha.kubernetes.io/hostname" = "unifi.${ccfg.domain}";
        };
        spec = {
          type = "LoadBalancer";
          selector."app.kubernetes.io/name" = "unifi";
          ipFamilies = (lib.optional ccfg.enableIPv4 "IPv4") ++ (lib.optional ccfg.enableIPv6 "IPv6");
          ports = [
            {
              name = "web";
              port = 443;
              targetPort = 8443;
            }
          ];
        }
        // (lib.optionalAttrs (ccfg.enableIPv4 && ccfg.enableIPv6) {
          ipFamilyPolicy = "RequireDualStack";
        });
      };
      overrides = {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          namespace = "unifi";
          name = "config-overrides";
          labels."app.kubernetes.io/name" = "unifi";
        };
        data."custom-environment-variables.json" = builtins.toJSON {
          postgres = {
            host = "PGHOST";
            port = "PGPORT";
            database = "PGDATABASE";
            user = "PGUSER";
            password = "PGPASSWORD";
          };
        };
      };
      service-account = {
        apiVersion = "v1";
        kind = "ServiceAccount";
        metadata = {
          namespace = "unifi";
          name = "unifi";
        };
      };
      role = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        metadata = {
          namespace = "unifi";
          name = "systemd1-shim-pod-get";
        };
        rules = [
          {
            apiGroups = [ "" ];
            resources = [ "pods" ];
            verbs = [ "get" ];
          }
        ];
      };
      role-binding = {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        metadata = {
          namespace = "unifi";
          name = "systemd1-shim-pod-get";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "unifi";
          }
        ];
        roleRef = {
          kind = "Role";
          name = "systemd1-shim-pod-get";
          apiGroup = "rbac.authorization.k8s.io";
        };
      };
      service-macro = {
        apiVersion = "cluster.local";
        kind = "ServiceMacro";
        metadata.name = "unifi";
        spec = {
          allowIngress = [
            "local-lan"
          ];
          allowEgress = [
            "internet"
            "postgresql"
          ];
          dataPath = "/persistent";
          servicePodSpec =
            let
              sharedMounts = {
                "/data/uos_uuid" = {
                  name = "data";
                  subPath = "uos_uuid";
                };
                "/usr/lib/version" = {
                  name = "data";
                  subPath = "version";
                };
                "/usr/lib/platform" = {
                  name = "data";
                  subPath = "platform";
                };
                "/usr/lib/product_name" = {
                  name = "data";
                  subPath = "product_name";
                };
              };
            in
            {
              serviceAccountName = "unifi";
              shareProcessNamespace = true;
              initContainersByName.init-uos = {
                image = "${container-utils.buildArgs.name}:${container-utils.imageTag}";
                imagePullPolicy = "Never";
                args = [
                  ''
                    set -eo pipefail
                    [[ -e /data/uos_uuid ]] || ${lib.getExe' pkgs.util-linux "uuidgen"} -s -n @dns -N "unifi-static" >/data/uos_uuid
                    APP_VERSION=$(jq -re .version /mnt/unifi-os/usr/share/unifi-core/app/package.json)
                    echo "$APP_MODEL.0000000.$APP_VERSION.0000000.000000.0000" > /data/version
                    echo "$FIRMWARE_PLATFORM" > /data/platform
                    echo "$PRODUCT_NAME" > /data/product_name

                    mkdir -p \
                      /data/unifi-core \
                      /data/uid-agent/ws
                    chmod g+ws \
                      /data/unifi-core \
                      /data/uid-agent/ws

                    rm -f /tmp/dbus/run/pid

                    mkdir -p \
                      /tmp/unifi-core/unifi-portal \
                      /tmp/unifi-core/uhd-setup \
                      /tmp/unifi-core/debug
                    cp -Ta --update /mnt/unifi-os/usr/share/unifi-core/app/node_modules/@ubnt/unifi-portal/dist/local /tmp/unifi-core/unifi-portal
                    cp -Ta --update /mnt/unifi-os/usr/share/unifi-core/app/node_modules/@ubnt/uhd-setup/dist /tmp/unifi-core/uhd-setup

                    cat >/tmp/unifi-core/debug/debug-prehook.js <<'EOF'
                    function dump(label, reason) {
                      if (reason && typeof reason === "object") {
                        const props = Object.getOwnPropertyNames(reason).reduce((acc, k) => {
                          acc[k] = reason[k];
                          return acc;
                        }, {});
                        console.error("[debug-prehook] " + label + ":", props, reason.stack || "(no stack)");
                      } else {
                        console.error("[debug-prehook] " + label + ":", reason);
                      }
                    }
                    process.on("unhandledRejection", (reason) => dump("unhandledRejection", reason));
                    process.on("uncaughtException", (reason) => dump("uncaughtException", reason));
                    EOF

                    {
                      grep '^Z ' /mnt/unifi-os/usr/share/zoneinfo/tzdata.zi | while read Z name rest; do
                        echo "$name"
                      done
                      grep '^L ' /mnt/unifi-os/usr/share/zoneinfo/tzdata.zi | while read L target name; do
                        echo "$name"
                      done
                    } | sort -u >/data/unifi-core/timezones.txt
                  ''
                ];
                securityContext.runAsUser = 0;
                securityContext.readOnlyRootFilesystem = true;
                envByName = {
                  APP_MODEL = "UOSSERVER";
                  FIRMWARE_PLATFORM = if pkgs.stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64";
                  PRODUCT_NAME = "uosserver";
                };
                volumeMountsByPath."/tmp" = "tmp";
                volumeMountsByPath."/data" = "data";
                volumeMountsByPath."/mnt/unifi-os" = "unifi-os-root";
              };
              mainContainer = {
                image = unifiOSImgName;
                imagePullPolicy = "Never";
                workingDir = "/usr/lib/unifi";
                securityContext.runAsUser = unifiOSUIDs.unifi;
                command = [ "/usr/bin/java" ];
                args = [
                  "-Dfile.encoding=UTF-8"
                  "-Djava.awt.headless=true"
                  "-Dapple.awt.UIElement=true"
                  "-Dunifi.core.enabled=true"
                  "-Dunifi.mongodb.service.enabled=false"
                  "-Dunifi.rmq.enabled=false"
                  "-Dunifi.external_disk.inserted="
                  "-Dspring.profiles.active=unifi-os"
                  "-Dunifi-os.server=true"
                  "-Dorg.xerial.snappy.tempdir=/usr/lib/unifi/run"
                  "-XX:+UseG1GC"
                  "-XX:MaxRAMPercentage=70.0"
                  "-Xss1024K"
                  "-XX:-TieredCompilation"
                  "-XX:+ExitOnOutOfMemoryError"
                  "-XX:+CrashOnOutOfMemoryError"
                  "-XX:ErrorFile=/usr/lib/unifi/logs/unifi_crash.log"
                  "-Xlog:gc:logs/gc.log:time:filecount=2,filesize=5M"
                  "--add-opens"
                  "java.base/java.lang=ALL-UNNAMED"
                  "--add-opens"
                  "java.base/java.time=ALL-UNNAMED"
                  "--add-opens"
                  "java.base/sun.security.util=ALL-UNNAMED"
                  "--add-opens"
                  "java.base/java.io=ALL-UNNAMED"
                  "--add-opens"
                  "java.rmi/sun.rmi.transport=ALL-UNNAMED"
                  "-jar"
                  "/usr/lib/unifi/lib/ace.jar"
                ];
                volumeMountsByPath = {
                  "/var/lib/unifi" = {
                    name = "data";
                    subPath = "unifi/data";
                  };
                  "/data/unifi/logs" = {
                    name = "data";
                    subPath = "unifi/logs";
                  };
                  "/data/unifi/run" = {
                    name = "data";
                    subPath = "unifi/run";
                  };
                }
                // sharedMounts;
              };
              containersByName = {
                unifi-core = {
                  image = unifiOSImgName;
                  imagePullPolicy = "Never";
                  workingDir = "/usr/share/unifi-core/app";
                  securityContext.runAsUser = 0;
                  securityContext.capabilities.add = [ "SYS_ADMIN" ];
                  securityContext.seccompProfile.type = "Unconfined";
                  command = [ "/usr/bin/node24" ];
                  args = [
                    "--expose-gc"
                    "--max-old-space-size=300"
                    "--openssl-legacy-provider"
                    "--no-network-family-autoselection"
                    "--dns-result-order=ipv4first"
                    "/usr/share/unifi-core/app/service.js"
                  ];
                  envByName = {
                    NODE_ENV = "production";
                    UV_THREADPOOL_SIZE = "256";
                    NODE_CONFIG_DIR = "/usr/share/unifi-core/app/config/:/data/unifi-core/config/overrides/";
                    NODE_CONFIG = ''{"discovery":{"discoveryClientUrl":"http://127.0.0.1:11002"}}'';
                    PKG = "unifi-core";
                    PGHOST = "postgresql.postgresql";
                    PGUSER = "unifi";
                    PGPASSWORD = "unifi";
                    PGPORT = "5432";
                    DB_USER = "unifi";
                    DB_PORT = "5432";
                    PGDATABASE = "unifi";
                    NODE_OPTIONS = "--require=/usr/share/unifi-core/app/debug/debug-prehook.js";
                    DBUS_SYSTEM_BUS_ADDRESS = "unix:path=/run/dbus/system_bus_socket";
                  };
                  volumeMountsByPath = {
                    "/data/unifi-core" = {
                      name = "data";
                      subPath = "unifi-core";
                    };
                    "/usr/share/unifi-core/app/node_modules/@ubnt/unifi-portal/dist/local" = {
                      name = "tmp";
                      subPath = "unifi-core/unifi-portal";
                    };
                    "/usr/share/unifi-core/app/node_modules/@ubnt/uhd-setup/dist" = {
                      name = "tmp";
                      subPath = "unifi-core/uhd-setup";
                    };
                    "/usr/share/unifi-core/app/debug" = {
                      name = "tmp";
                      subPath = "unifi-core/debug";
                    };
                    "/usr/share/unifi-core/app/config/custom-environment-variables.json" = {
                      name = "overrides";
                      subPath = "custom-environment-variables.json";
                    };
                    "/run/dbus" = {
                      name = "tmp";
                      subPath = "dbus/run";
                    };
                  }
                  // sharedMounts;
                };
                debug = {
                  image = "${container-utils.buildArgs.name}:${container-utils.imageTag}";
                  imagePullPolicy = "Never";
                  args = [
                    ''
                      trap "kill \$PID; exit 0" TERM
                      sleep 3600 & PID=$!
                      wait $PID
                    ''
                  ];
                  volumeMountsByPath."/tmp" = "tmp";
                  volumeMountsByPath."/data" = "data";
                  volumeMountsByPath."/mnt/unifi-os" = "unifi-os-root";
                };
                unifi-credential-server = {
                  image = unifiOSImgName;
                  imagePullPolicy = "Never";
                  workingDir = "/data/ulp-go/ws";
                  securityContext.runAsUser = unifiOSUIDs.unifi-credential-server;
                  command = [ "/usr/sbin/unifi-credential-server-app" ];
                  args = [
                    "--prop"
                    "/usr/lib/unifi-credential-server/config.props"
                    "--user-assets-prop"
                    "/data/ucs-user-assets/config.props"
                  ];
                  volumeMountsByPath = {
                    "/data/unifi-credential-server" = {
                      name = "data";
                      subPath = "unifi-credential-server";
                    };
                  }
                  // sharedMounts;
                };
                ucs-agent = {
                  image = unifiOSImgName;
                  imagePullPolicy = "Never";
                  workingDir = "/data/ucs-agent/ws";
                  securityContext.runAsUser = unifiOSUIDs.ucs-agent;
                  command = [ "/usr/sbin/ucs-agent-app" ];
                  args = [
                    "--prop"
                    "/usr/lib/ucs-agent/config.props"
                  ];
                  volumeMountsByPath = {
                    "/data/ucs-agent" = {
                      name = "data";
                      subPath = "ucs-agent";
                    };
                  }
                  // sharedMounts;
                };
                unifi-identity-update = {
                  image = unifiOSImgName;
                  imagePullPolicy = "Never";
                  securityContext.runAsUser = unifiOSUIDs.ucs-update;
                  command = [ "/usr/sbin/unifi-identity-update-app" ];
                  args = [
                    "--prop"
                    "/usr/lib/unifi-identity-update/config.props"
                  ];
                  volumeMountsByPath = {
                    "/var/log/unifi_package-identity-update" = {
                      name = "data";
                      subPath = "unifi-identity-update/logs";
                    };
                    "/run/dbus" = {
                      name = "tmp";
                      subPath = "dbus/run";
                    };
                  }
                  // sharedMounts;
                };
                uid-agent = {
                  image = unifiOSImgName;
                  imagePullPolicy = "Never";
                  workingDir = "/data/uid-agent/ws";
                  securityContext.runAsUser = unifiOSUIDs.uid;
                  command = [ "/usr/sbin/uid-agent-app" ];
                  args = [
                    "--props"
                    "/usr/lib/uid-agent/config.props"
                  ];
                  volumeMountsByPath = {
                    "/data/uid" = {
                      name = "data";
                      subPath = "uid-agent";
                    };
                  }
                  // sharedMounts;
                };
                ulp = {
                  image = unifiOSImgName;
                  imagePullPolicy = "Never";
                  workingDir = "/data/ulp-go/ws";
                  securityContext.runAsUser = unifiOSUIDs.ulp-go;
                  command = [ "/usr/sbin/ulp-go-app" ];
                  args = [
                    "--prop"
                    "/usr/lib/ulp-go/config.props"
                  ];
                  volumeMountsByPath = {
                    "/data/ulp-go" = {
                      name = "data";
                      subPath = "ulp-go";
                    };
                  }
                  // sharedMounts;
                };
                uos-discovery-client = {
                  image = unifiOSImgName;
                  imagePullPolicy = "Never";
                  command = [ "/usr/bin/uos-discovery-client" ];
                  volumeMountsByPath = { } // sharedMounts;
                };
                systemd = {
                  image = "ghcr.io/andsens/systemd1-shim:sha-aef6950-debian";
                  args = [ "--hook=k8s" ];
                  securityContext.runAsUser = 0;
                  envByName = {
                    POD_NAME.valueFrom.fieldRef.fieldPath = "metadata.name";
                    NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                  };
                  volumeMountsByPath = {
                    "/run/dbus" = {
                      name = "tmp";
                      subPath = "dbus/run";
                    };
                  };
                };
                nginx = {
                  image = unifiOSImgName;
                  imagePullPolicy = "Never";
                  command = [ "/usr/sbin/nginx" ];
                  args = [
                    "-c"
                    "/etc/nginx/nginx.conf"
                  ];
                  volumeMountsByPath = {
                    "/var/log/nginx" = {
                      name = "data";
                      subPath = "nginx/logs";
                    };
                    "/run" = {
                      name = "tmp";
                      subPath = "nginx/run";
                    };
                    "/tmp" = {
                      name = "tmp";
                      subPath = "nginx/tmp";
                    };
                  };
                };
              };
              volumesByName = {
                tls.secret.secretName = "unifi-tls";
                tmp.emptyDir = { };
                overrides.configMap.name = "config-overrides";
                unifi-os-root = {
                  image = {
                    reference = unifiOSImgName;
                    pullPolicy = "Never";
                  };
                };
              };
            };
        };
      };
    };
  };
}
