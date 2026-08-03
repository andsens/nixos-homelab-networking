{ inputs, self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.clientVPN;
  container-utils = inputs.homelab.packages.${pkgs.stdenv.hostPlatform.system}.container-utils;
  hllib = inputs.homelab.lib;
  libIPv4 = hllib.ip.v4;
  listenPort = 51820;
  upScript = pkgs.writeShellScriptBin "up.sh" ''
    ${lib.getExe' pkgs.wireguard-tools "wg-quick"} up clients
    for sig in INT TERM EXIT; do
      trap "${lib.getExe' pkgs.wireguard-tools "wg-quick"} down clients; kill $SLEEP_PID" $sig
    done
    (while true; do sleep 600; done) &
    wait $!
  '';
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/wireguard";
    copyToRoot = [
      pkgs.bash
      upScript
      pkgs.iptables
      pkgs.wireguard-tools
      pkgs.coreutils # needed by wg-quick
    ]
    ++ lib.optionals cfg.debug ccfg.debugTools;
    config.User = "0:0";
    config.Entrypoint = [
      (pkgs.lib.getExe upScript)
    ];
  };
  enabledPeerConfigs = peers: lib.filterAttrs (name: value: value.config.enable) peers;
  enabledGroupConfigs =
    lib.mapAttrs (name: value: builtins.head (builtins.attrValues (enabledPeerConfigs value.peers)))
      (
        lib.filterAttrs (
          name: value: builtins.length (builtins.attrNames (enabledPeerConfigs value.peers)) == 1
        ) cfg.groups
      );
in
{
  options.homelab.clientVPN = {
    enable = lib.mkEnableOption "the client VPN gateway";
    debug = lib.mkEnableOption "debug mode";
    groups = lib.mkOption {
      description = "VPN client access groups, indexed by group name. Each group is a wireguard endpoint.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }@subm:
          let
            parsedCIDR4 = libIPv4.fromString subm.config.cidr4;
            peerIPs = lib.mergeAttrsList (
              lib.imap (idx: spec: {
                ${spec.name} = libIPv4.cidrIndex parsedCIDR4 (1 + idx) // {
                  prefixLength = 32;
                };
              }) (lib.sortOn ({ name, value }: name) (lib.attrsToList cfg.groups.${name}.peers))
            );
          in
          {
            options = {
              allowEgress = lib.mkOption {
                description = "List of services this group should be granted access to \"gateway\" is needed for access to gateway (use e.g. [\"gateway\" \"sabnzbd\"] to grant access to sabnzbd only), \"cluster\" gives full access to the cluster";
                type = lib.types.listOf lib.types.str;
              };
              reservedIPs = lib.mkOption {
                description = "Reserved IPs for the VPN endpoint";
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
              cidr4 = lib.mkOption {
                description = "IPv4 CIDR of the tunnel";
                type = lib.types.str;
              };
              gatewayIP = lib.mkOption {
                description = "IPv4 of the gateway";
                type = lib.types.attrsOf lib.types.anything;
                readOnly = true;
                default = (libIPv4.cidrIndex parsedCIDR4 1) // {
                  prefixLength = 32;
                };
              };
              gatewayPublicKey = lib.mkOption {
                description = "Public key of the gateway for inline in ready-made client configurations";
                type = lib.types.str;
              };
              peers = lib.mkOption {
                description = "VPN Peers in this group";
                type = lib.types.attrsOf (
                  lib.types.submodule (
                    {
                      name,
                      config,
                      ...
                    }:
                    {
                      options = {
                        enable = lib.mkEnableOption "the peer";
                        config.enable = lib.mkEnableOption "the wireguard & setup-secrets configuration corresponding to this peer, at most one configuration per group can be enabled at the same time";
                        ipv4 = lib.mkOption {
                          description = "The IPv4 of the peer";
                          type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
                          readOnly = true;
                          default = peerIPs.${name};
                        };
                        publicKey = lib.mkOption {
                          description = "Public key of the peer";
                          type = lib.types.str;
                        };
                      };
                    }
                  )
                );
              };
            };
          }
        )
      );
    };
  };
  imports = [
    inputs.setup-secrets.nixosModules.default
    self.nixosModules.routed-ippool
  ];
  config = {
    assertions =
      (lib.optional cfg.enable [
        {
          assertion = config.homelab.routedIPPool.enable;
          message = "Client VPN depends on the routed loadbalancer IP Pool module. Enable with `homelab.routedIPPool = { enable=true; lbIpBlock4.cidr = ...; }`";
        }
      ])
      ++ (lib.mapAttrsToList (
        name: value:
        let
          names = builtins.attrNames (enabledPeerConfigs value.peers);
        in
        {
          assertion = builtins.length names <= 1;
          message = "The Client VPN group '${name}' has multiple peer configurations enabled (${lib.join ", " names}), this is not supported";
        }
      ) cfg.groups);
    networking.wireguard.interfaces = lib.mapAttrs' (
      name: value:
      lib.nameValuePair "homelab-${name}" {
        ips = lib.mkDefault [
          (libIPv4.toCIDR value.ipv4)
        ];
        mtu = lib.mkDefault 1280;
        peers = [
          {
            allowedIPs = lib.mkDefault (
              (lib.optional ccfg.enableIPv4 config.homelab.routedIPPool.lbIpBlock4.cidr)
              ++ (lib.optional ccfg.enableIPv6 config.homelab.routedIPPool.lbIpBlock6.cidr)
            );
            endpoint = lib.mkDefault "${name}-vpn.${ccfg.domain}:51820";
            publicKey = lib.mkDefault cfg.groups.${name}.gatewayPublicKey;
          }
        ];
        privateKeyFile = lib.mkDefault "/etc/secrets.d/homelab-${name}.vpn-key";
      }
    ) enabledGroupConfigs;
    setup-secrets.sources =
      (lib.mapAttrs' (
        group: spec:
        lib.nameValuePair "CLIENT_VPN_${lib.toUpper group}" {
          enable = cfg.enable;
          description = "Client VPN ${group} private key";
          cmd = hllib.setup-secrets.mkScript pkgs ''
            getKubeSecret client-vpn client-vpn-private-keys ${group} || \
            ${lib.getExe' pkgs.wireguard-tools "wg"} genkey
          '';
        }
      ) cfg.groups)
      // (lib.mapAttrs' (
        name: value:
        lib.nameValuePair "HOMELAB_${lib.toUpper name}_VPN_PRIVATE_KEY" {
          description = "Private Key for homelab ${name} VPN connection";
          cmd = hllib.setup-secrets.mkScript pkgs ''cat "${
            config.networking.wireguard.interfaces."homelab-${name}".privateKeyFile
          }"'';
        }
      ) enabledGroupConfigs);
    setup-secrets.destinations = [
      {
        enable = cfg.enable;
        logPrefix = "Client VPN Private Keys";
        requires = map (group: "CLIENT_VPN_${lib.toUpper group}") (builtins.attrNames cfg.groups);
        cmd = hllib.setup-secrets.mkScript pkgs ''
          kubectl create secret generic -n client-vpn --dry-run=client -oyaml client-vpn-private-keys \
            ${
              lib.join "\\ \n" (
                map (group: ''--from-literal=${group}="$CLIENT_VPN_${group}"'') (builtins.attrNames cfg.groups)
              )
            } \
            -oyaml | \
            kubectl apply -f -
        '';
      }
    ]
    ++ (lib.mapAttrsToList (
      name: value:
      let
        envvar = "HOMELAB_${lib.toUpper name}_VPN_PRIVATE_KEY";
      in
      {
        logPrefix = "Homelab ${name} VPN Private Key File";
        requires = [ envvar ];
        cmd = hllib.setup-secrets.mkScript pkgs ''
          umask 077
          printf "%s" "$${envvar}" >"${
            config.networking.wireguard.interfaces."homelab-${name}".privateKeyFile
          }"
        '';
      }
    ) enabledGroupConfigs);
    services.k3s.images = lib.optional cfg.enable [ image ];
    services.k3s.manifests.client-vpn.enable = cfg.enable;
    kubetree.resources.client-vpn = {
      namespace = {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = "client-vpn";
      };
      config = {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          namespace = "client-vpn";
          name = "config";
          labels."app.kubernetes.io/name" = "client-vpn";
        };
        data = lib.mapAttrs' (
          group: spec:
          lib.nameValuePair "${group}.conf" ''
            [Interface]
            PrivateKey = ''${PRIVATE_KEY}
            Address = ${libIPv4.toCIDR spec.gatewayIP}
            ListenPort = ${builtins.toString listenPort}
            PostUp   = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
            PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

            ${lib.join "\n" (
              lib.mapAttrsToList (
                name:
                { ipv4, publicKey, ... }:
                ''
                  [Peer]
                  PublicKey = ${publicKey}
                  AllowedIPs = ${libIPv4.toCIDR ipv4}
                ''
              ) (lib.filterAttrs (name: value: value.enable) spec.peers)
            )}
          ''
        ) cfg.groups;
      };
      wg-netpol = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumNetworkPolicy";
        metadata = {
          namespace = "client-vpn";
          name = "world-to-client-vpn";
          labels."app.kubernetes.io/name" = "client-vpn";
        };
        spec.endpointSelector.matchLabels."app.kubernetes.io/name" = "client-vpn";
        spec.ingress = [
          {
            fromEntities = [ "world" ];
            toPortsFlattened = [
              {
                port = listenPort;
                protocol = "UDP";
              }
            ];
          }
        ];
        spec.egress = [ { toEntities = [ "world" ]; } ];
      };
    }
    // lib.mergeAttrsList (
      lib.mapAttrsToList (group: spec: {
        "${group}-deployment" = {
          apiVersion = "cluster.local";
          kind = "ServiceDeployment";
          metadata = {
            namespace = "client-vpn";
            name = "${group}-vpn";
            labels = {
              "app.kubernetes.io/name" = "client-vpn";
              "app.kubernetes.io/component" = group;
            };
          };
          spec = {
            allowEgress = spec.allowEgress;
            servicePodSpec = {
              initContainersByName.render-config = {
                image = "${container-utils.buildArgs.name}:${container-utils.imageTag}";
                imagePullPolicy = "Never";
                args = [
                  ''
                    envsubst \''${PRIVATE_KEY} </config/${group}.conf >/config-tmp/clients.conf
                    chmod 600 /config-tmp/clients.conf
                  ''
                ];
                envByName.PRIVATE_KEY.valueFrom.secretKeyRef = {
                  name = "client-vpn-private-keys";
                  key = group;
                };
                securityContext = {
                  runAsUser = 0;
                  runAsGroup = 0;
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = [ "ALL" ];
                };
                volumeMountsByPath = {
                  "/config" = "config";
                  "/config-tmp" = "config-tmp";
                };
              };
              mainContainer = {
                image = "${image.buildArgs.name}:${image.imageTag}";
                imagePullPolicy = "Never";
                addCapabilities = [
                  "NET_ADMIN"
                  "SYS_MODULE"
                ];
                securityContext = {
                  runAsUser = 0;
                  runAsGroup = 0;
                };
                portsByName.wg = {
                  containerPort = listenPort;
                  protocol = "UDP";
                };
                volumeMountsByPath = {
                  "/etc/wireguard/clients.conf" = {
                    name = "config-tmp";
                    subPath = "clients.conf";
                  };
                  "/dev/net/tun" = "dev-net-tun";
                };
              };
              volumesByName = {
                dev-net-tun.hostPath = {
                  path = "/dev/net/tun";
                  type = "CharDevice";
                };
                config-tmp.emptyDir = { };
                config.configMap.name = "config";
              };
            };
          };
        };
        "${group}-service" = {
          apiVersion = "v1";
          kind = "Service";
          metadata = {
            namespace = "client-vpn";
            name = "${group}-vpn";
            labels = {
              "app.kubernetes.io/name" = "client-vpn";
              "app.kubernetes.io/component" = group;
              "cluster.local/ippool" = "routed";
            };
            annotations = {
              "external-dns.alpha.kubernetes.io/hostname" = "${group}-vpn.${ccfg.domain}";
            }
            // lib.optionalAttrs (builtins.length spec.reservedIPs > 0) ({
              "lbipam.cilium.io/ips" = lib.join "," spec.reservedIPs;
            });
          };
          spec = {
            type = "LoadBalancer";
            selector = {
              "app.kubernetes.io/name" = "client-vpn";
              "app.kubernetes.io/component" = group;
            };
            ipFamilies = (lib.optional ccfg.enableIPv4 "IPv4") ++ (lib.optional ccfg.enableIPv6 "IPv6");
            ports = [
              {
                name = "wg";
                port = listenPort;
                protocol = "UDP";
              }
            ];
          }
          // (lib.optionalAttrs (ccfg.enableIPv4 && ccfg.enableIPv6) {
            ipFamilyPolicy = "RequireDualStack";
          });
        };
      }) cfg.groups
    );
  };
}
