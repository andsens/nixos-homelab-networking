{ ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.homelab.cluster.external-dns;
  ccfg = config.homelab.cluster;
  external-dns = pkgs.buildGo126Module rec {
    name = "external-dns";
    version = "v0.21.0";
    meta.mainProgram = "external-dns";
    src = pkgs.fetchFromGitHub {
      owner = "kubernetes-sigs";
      repo = name;
      tag = version;
      hash = "sha256-oqEMIfq7wh3tPjO6ZZ9gwgEE6TwSWaP3GiUwhybo2B4=";
    };
    proxyVendor = true;
    vendorHash = "sha256-YFRYlo0WEfLG+A+bnQWUdFiJwclmLh9c8jCTKjDmPK8=";

    doCheck = false; # Tests require kubebuilder running through `make test`
  };
  externalDNSImage = pkgs.dockerTools.buildImage {
    name = "cluster.local/${external-dns.name}";
    copyToRoot = [ external-dns ] ++ lib.optionals cfg.debug ccfg.debugTools;
    config.User = "65534:65534";
    config.Entrypoint = [
      (pkgs.lib.getExe external-dns)
    ];
  };
  webhook = pkgs.buildGo126Module rec {
    name = "external-dns-libdns-webhook";
    version = "0.4.0";
    meta.mainProgram = "external-dns-libdns-webhook";
    src = pkgs.fetchFromGitHub {
      owner = "orbit-online";
      repo = name;
      rev = "1d119f3d687c18fcccd5fe34793024992aa89510";
      hash = "sha256-pxu16Ri1agvhbBiog+lCvTlN2SbnaMQZ+YCJXR63Oo0=";
    };
    proxyVendor = true;
    vendorHash = "sha256-gcRQRHOjFpT64Qm95FbwnF3jDdzigiiCsMlWu7ooeZw=";
  };
  webhookImage = pkgs.dockerTools.buildImage {
    name = "cluster.local/${webhook.name}";
    copyToRoot = [
      webhook
      pkgs.cacert
    ]
    ++ lib.optionals cfg.debug ccfg.debugTools;
    config.User = "1001:1001";
    config.Entrypoint = [
      (pkgs.lib.getExe webhook)
    ];
  };
in
{
  options.homelab.cluster.external-dns = {
    debug = lib.mkEnableOption "debug mode";
  };
  config = {
    services.k3s.images = [
      externalDNSImage
      webhookImage
    ];
    services.k3s.manifests = {
      dnsendpoint.source = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/tags/v0.20.0/charts/external-dns/crds/dnsendpoints.externaldns.k8s.io.yaml";
        hash = "sha256-lvQ4PVUKBNfHizMS7cbg+dq5d32Blf9M/cdqDKlYe74=";
      };
      external-dns-static.source = ./external-dns.yaml;
    };
    kubetree.resources = {
      external-dns.deployment = {
        apiVersion = "cluster.local";
        kind = "ServiceDeployment";
        metadata.name = "external-dns";
        spec = {
          allowEgress = [
            "apiserver"
            "internet"
          ];
          servicePodSpec = {
            serviceAccountName = "external-dns";
            mainContainer = {
              image = "${externalDNSImage.buildArgs.name}:${externalDNSImage.imageTag}";
              securityContext = {
                runAsGroup = 65534;
                runAsUser = 65534;
              };
              envByName = {
                EXTERNAL_DNS_SOURCE = ''
                  crd
                  service
                  ingress
                  gateway-httproute
                  gateway-tlsroute
                  gateway-grpcroute
                '';
                EXTERNAL_DNS_MANAGED_RECORD_TYPES = ''
                  A
                  AAAA
                  CNAME
                  MX
                '';
                EXTERNAL_DNS_EVENTS_EMIT = ''
                  RecordReady
                  RecordDeleted
                  RecordError
                '';
                EXTERNAL_DNS_TXT_PREFIX = "edns-%{record_type}.";
                EXTERNAL_DNS_TXT_OWNER_ID = "homelab";
                EXTERNAL_DNS_EVENTS = "1";
                EXTERNAL_DNS_INTERVAL = "5m";
                EXTERNAL_DNS_PROVIDER = "webhook";
                EXTERNAL_DNS_MIN_TTL = "300s";
              };
              portsByName.metrics = 7979;
              livenessProbe.httpGet = {
                path = "/healthz";
                port = "metrics";
              };
              readinessProbe.httpGet = {
                path = "/healthz";
                port = "metrics";
              };
            };
            containersByName.external-dns-node-source = {
              image = "${externalDNSImage.buildArgs.name}:${externalDNSImage.imageTag}";
              securityContext = {
                runAsGroup = 65534;
                runAsUser = 65534;
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.add = [ "NET_BIND_SERVICE" ];
                capabilities.drop = [ "ALL" ];
              };
              envByName = {
                EXTERNAL_DNS_METRICS_ADDRESS = ":7980";
                EXTERNAL_DNS_FQDN_TEMPLATE = "{{ .Name }}.${ccfg.domain}";
                EXTERNAL_DNS_SOURCE = "node";
                EXTERNAL_DNS_EXPOSE_INTERNAL_IPV6 = "1";
                EXTERNAL_DNS_EVENTS_EMIT = ''
                  RecordReady
                  RecordDeleted
                  RecordError
                '';
                EXTERNAL_DNS_TXT_PREFIX = "edns-%{record_type}.";
                EXTERNAL_DNS_TXT_OWNER_ID = "homelab-node-source";
                EXTERNAL_DNS_EVENTS = "1";
                EXTERNAL_DNS_INTERVAL = "5m";
                EXTERNAL_DNS_PROVIDER = "webhook";
                EXTERNAL_DNS_MIN_TTL = "300s";
              };
              portsByName.metrics-node = 7980;
              livenessProbe.httpGet = {
                path = "/healthz";
                port = "metrics-node";
              };
              readinessProbe.httpGet = {
                path = "/healthz";
                port = "metrics-node";
              };
            };
            containersByName.external-dns-libdns-webhook = {
              name = "external-dns-libdns-webhook";
              image = "${webhookImage.buildArgs.name}:${webhookImage.imageTag}";
              imagePullPolicy = "Never";
              securityContext = {
                runAsGroup = 65534;
                runAsUser = 65534;
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.add = [ "NET_BIND_SERVICE" ];
                capabilities.drop = [ "ALL" ];
              };
              envByName = {
                LIBDNS_PROVIDER_ZONES = config.homelab.cluster.domain;
                LIBDNS_WEBHOOK_LISTEN = ":8888";
              };
              portsByName.api = 8888;
              livenessProbe.httpGet = {
                path = "/healthz";
                port = 8888;
              };
              readinessProbe.httpGet = {
                path = "/healthz";
                port = 8888;
              };
            };
          };
        };
      };
    };
  };
}
