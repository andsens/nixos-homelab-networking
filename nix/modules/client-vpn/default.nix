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
  ipv4 = hllib.ip.v4;
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
in
{
  options.homelab.clientVPN = {
    enable = lib.mkEnableOption "the client VPN gateway";
    debug = lib.mkEnableOption "debug mode";
    lbIpBlock4.cidr = lib.mkOption {
      description = "IPv4 CIDR for the VPN gateways";
      type = lib.types.nullOr lib.types.str;
      default = "10.45.0.0/16";
    };
    lbIpBlock4.start = lib.mkOption {
      description = "IPv4 Pool range start for the VPN gateways";
      type = lib.types.str;
      default = "10.45.0.2";
    };
    lbIpBlock4.stop = lib.mkOption {
      description = "IPv4 Pool range end for the VPN gateways";
      type = lib.types.str;
      default = "10.45.0.254";
    };
    lbIpBlock6.cidr = lib.mkOption {
      description = "IPv6 CIDR for the VPN gateways";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    lbIpBlock6.start = lib.mkOption {
      description = "IPv6 Pool range start for the VPN gateways";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    lbIpBlock6.stop = lib.mkOption {
      description = "IPv6 Pool range end for the VPN gateways";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    groups = lib.mkOption {
      description = "VPN client access groups, indexed by group name. Each group is a wireguard endpoint.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          {
            name,
            config,
            ...
          }:
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
                default = "10.16.189.0/24";
              };
              gatewayIP = lib.mkOption {
                description = "IPv4 of the gateway";
                type = lib.types.str;
                readOnly = true;
                default = "${(ipv4.cidrIndex (ipv4.fromString config.cidr4) 1).address}";
              };
              peers = lib.mkOption {
                description = "List of VPN client public keys, the order dictates the IP assigned from the CIDR (from x.y.z.2 onwards)";
                type = lib.types.listOf lib.types.str;
              };
              # run `nix build '.#nixosConfigurations."<HOSTNAME>".config.homelab.clientVPN.groups.<GROUPNAME>.clientConfig' --impure` to output the payload
              clientConfig = lib.mkOption {
                description = "A derivation that specifies the wireguard client configuration";
                type = lib.types.package;
                readOnly = true;
                default =
                  let
                    allowedIPs =
                      (lib.optional ccfg.enableIPv4 ccfg.lbIpBlock4.cidr)
                      ++ (lib.optional ccfg.enableIPv6 ccfg.lbIpBlock6.cidr);
                  in
                  pkgs.writeText "${name}.conf" ''
                    [Interface]
                    PrivateKey = <PRIVATE KEY>
                    Address = ${config.gatewayIP}/32
                    MTU = 1280 # Important, there's quite a bit of routing overhead

                    [Peer]
                    PublicKey = <PUBLIC KEY>
                    AllowedIPs = ${lib.join ", " allowedIPs}
                    Endpoint =  ${name}-vpn.${ccfg.domain}:51820
                  '';
              };
            };
          }
        )
      );
    };
  };
  imports = [ inputs.setup-secrets.nixosModules.default ];
  config = lib.mkIf cfg.enable {
    services.k3s.images = [ image ];
    setup-secrets = {
      sources = lib.mapAttrs' (
        group: spec:
        lib.nameValuePair "CLIENT_VPN_${group}" {
          description = "Client VPN ${group} private key";
          cmd = hllib.setup-secrets.mkScript pkgs ''
            getKubeSecret client-vpn client-vpn-private-keys ${group} || \
            ${lib.getExe' pkgs.wireguard-tools "wg"} genkey
          '';
        }
      ) cfg.groups;
      destinations = [
        {
          logPrefix = "Client VPN Private Keys";
          requires = map (group: "CLIENT_VPN_${group}") (builtins.attrNames cfg.groups);
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
      ];
    };
    kubetree.resources.client-vpn = {
      namespace = {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = "client-vpn";
      };
      cilium-lbippool = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumLoadBalancerIPPool";
        metadata.name = "client-vpn";
        spec.blocks =
          (lib.optional ccfg.enableIPv4 (
            if cfg.lbIpBlock4.start != null then
              { inherit (cfg.lbIpBlock4) start stop; }
            else
              { inherit (cfg.lbIpBlock4) cidr; }
          ))
          ++ (lib.optional ccfg.enableIPv6 (
            if cfg.lbIpBlock6.start != null then
              { inherit (cfg.lbIpBlock6) start stop; }
            else
              { inherit (cfg.lbIpBlock6) cidr; }
          ));
        spec.serviceSelector.matchLabels."app.kubernetes.io/name" = "client-vpn";
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
          let
            parsedCIDR4 = ipv4.fromString spec.cidr4;
          in
          lib.nameValuePair "${group}.conf" ''
            [Interface]
            PrivateKey = ''${PRIVATE_KEY}
            Address = ${ipv4.toCIDR (ipv4.cidrIndex parsedCIDR4 1)}
            ListenPort = ${builtins.toString listenPort}
            PostUp   = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
            PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

            ${lib.join "\n" (
              lib.imap (idx: publicKey: ''
                [Peer]
                PublicKey = ${publicKey}
                AllowedIPs = ${(ipv4.cidrIndex parsedCIDR4 (1 + idx)).address}/32
              '') spec.peers
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
