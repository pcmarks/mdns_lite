# MdnsLite

[![Hex version](https://img.shields.io/hexpm/v/mdns_lite.svg "Hex version")](https://hex.pm/packages/mdns_lite)
[![CircleCI](https://circleci.com/gh/pcmarks/mdns_lite.svg?style=svg)](https://circleci.com/gh/pcmarks/mdns_lite)

MdnsLite is a simple, limited, no frills implementation of an
[mDNS](https://en.wikipedia.org/wiki/Multicast_DNS) (multicast Domain Name System)
server. It operates like a DNS server, the difference being that it uses multicast
instead of unicast and is meant to be the DNS server for the _.local_ domain. MdnsLite
also provides for the advertising (discovery) of services offered by the host system.
Examples of services are an HTTP or an SSH server. Read about configuring
services in the Configuration section below.

MdnsLite employs a network interface monitor that can dynamically adjust to
network changes, e.g., assignment of a new IP address to a host. The current
version of MdnsLite supports two default monitors:

* `InetMonitor` which periodically checks via `inet:getifaddrs()` for changes
  in the network. For example, a change could be the re-assignment of IP
  addresses.

* `VintageNetMonitor` which subscribes to [`VintageNet`](https://github.com/nerves-networking/vintage_net) address events for all
interfaces as they happen.

For configuration values related to the interface monitor, please see the Configuration
section below.

MdnsLite recognizes the following [query types](https://en.wikipedia.org/wiki/List_of_DNS_record_types):

* A - Find the IPv4 address of a hostname.
* PTR - Given an IPv4 address, find its hostname - reverse lookup. If, however, it receives a request domain of
"_services._dns-sd._udp.local", MdnsLite will respond with a list of
every service available (and is specified in the configuration) on the host.
* SRV - Service Locator

If you want to know the details of the various DNS/mDNS record types and their fields,
a good source is
[zytrax.com/books/dns](http://www.zytrax.com/books/dns).

There are at least a couple of other Elixir/Erlang implementations of mDNS servers:

1. [Rosetta Home mdns](https://github.com/rosetta-home/mdns) (Elixir)
2. [Shortishly mdns](https://github.com/shortishly/mdns) (Erlang)

These implementations provided valuable guidance in the building of MdnsLite.

## Configuration

A typical configuration in the `config.exs` file looks
like:

```elixir
config :mdns_lite,
  # Use these values to construct the DNS resource record responses
  # to a DNS query.
  host: :hostname,
  ttl: 120,
  services: [
    # service type: _http._tcp.local - used in match
    %{
      name: "Web Server",
      protocol: "http",
      transport: "tcp",
      port: 80,
    },
    # service_type: _ssh._tcp.local - used in match
    %{
      name: "Secure Socket",
      protocol: "ssh",
      transport: "tcp",
      port: 22,
    }
  ]
```

(Note that the configuration changed from v0.2 to v0.3, eliminating a superfluous map.)

The values of `host` and `ttl` will be used in the construction of mDNS (DNS) responses.

`host` can have the value of  `:hostname` in which case the value will be
replaced with the value of `:inet.gethostname()`, otherwise you can provide a
string value. You can specify an alias hostname in which case `host` will be
`["hostname", "alias-example"]`. The second value must be a string. When you use
an alias, an "A" query can be made to  `alias-example.local` as well as to
`hostname.local`. This can also be configured at runtime via
`MdnsLite.set_host/1`:

```elixir
iex)> MdnsLite.set_host([:hostname, "nerves"])
:ok
```

`ttl` refers to a Time To Live value in seconds. [RFC 6762 - Multicast
DNS](https://tools.ietf.org/html/rfc6762) - recommends a default value of 120 seconds.

As mentioned above, `MdnsLite` uses an interface monitor. The configuration
value `ip_address_monitor` (not shown) defaults to `VintageNetMonitor` if
[`VintageNet`](https://github.com/nerves-networking/vintage_net) is added as a dependency to your project using `MdnsLite`.
Otherwise, `InetMonitor` will be the default. The
configuration value `excluded_ifnames` represents those interfaces that the
monitor will **not** watch. Its default value is `["lo0", "lo"]`.

The `services` section lists the services that the host offers,
such as providing an HTTP server. You must supply the `protocol`, `transport` and
`port` values for each service. You may also specify `weight` and/or `host`.
They each default to a zero value. Please consult the RFC for an explanation of
these values. Services can be configured in `config.exs` as shown above, or at
runtime:

```elixir
iex)> services = [
  # service type: _http._tcp.local - used in match
  %{
    name: "Web Server",
    protocol: "http",
    transport: "tcp",
    port: 80,
  },
  # service_type: _ssh._tcp.local - used in match
  %{
    name: "Secure Socket",
    protocol: "ssh",
    transport: "tcp",
    port: 22,
  }
]

iex)> MdnsLite.add_mds_services(services)
:ok
```

Services can also be removed at runtime via `remove_mdns_services/1` with the
service name to remove:

```elixir
iex)> service_names = ["Web Server", "Secure Socket"]
iex)> MdnsLite.remove_mdns_services(services)
:ok

# Remove just a single service
iex)> MdnsLite.remove_mdns_services("Secure Socket")
:ok
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `mdns_lite` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mdns_lite, "~> 0.4"}
  ]
end
```

## Usage

`MdnsLite` is an Elixir/Erlang application; it will start up automatically when
its enclosing application starts.

When MdnsLite is running, it can be tested using the linux `dig` utility:

```sh
$ dig @224.0.0.251 -p 5353 -t A nerves-7fcb.local
...
nerves-7fcb.local. 120  IN  A 192.168.0.106
...
$ dig @224.0.0.251 -p 5353 -x 192.168.0.106
...
106.0.168.192.in-addr.arpa. 120 IN  PTR nerves-7fcb.local.
...
$ dig @nerves-7fcb.local -p 5353 -t PTR _ssh._tcp.local
...
_ssh._tcp.local.  120 IN  PTR nerves-7fcb._ssh._tcp.local.
nerves-7fcb._ssh._tcp.local. 120 IN TXT ""
nerves-7fcb._ssh._tcp.local. 120 IN SRV 0 0 22 nerves-7fcb.local.
nerves-7fcb.local.  120 IN  A 192.168.0.106
...
$ dig @224.0.0.251 -p 5353 -t SRV nerves-7fcb._ssh._tcp.local
...
nerves-7fcb._ssh._tcp.local. 120 IN SRV 0 0 22 nerves-7fcb.local.
nerves-7fcb.local.  120 IN  A 192.168.0.106
...
```

Although `dig` is a lookup utility for DNS, it can be used to query `MdnsLite`. You can use the reserved ip address (`224.0.0.251`) and port(`5353`) and query the local domain. Or you can use the local hostname, e.g., `nerves-7fcb.local` of the host that is providing the mDNS responses along with port `5353`.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/mdns_lite](https://hexdocs.pm/mdns_lite).
