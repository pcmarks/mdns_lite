defmodule MdnsLite.ConfigurationTest do
  use ExUnit.Case, async: false

  alias MdnsLite.Configuration

  setup do
    # Make sure we're starting with known state every time
    :sys.replace_state(Configuration, fn s -> %{s | mdns_services: MapSet.new()} end)

    %{
      result: %{
        name: "SSH Remote Login Protocol",
        port: 22,
        priority: 0,
        protocol: "ssh",
        transport: "tcp",
        type: "_ssh._tcp",
        weight: 0
      },
      service: %{
        name: "SSH Remote Login Protocol",
        protocol: "ssh",
        transport: "tcp",
        port: 22
      }
    }
  end

  test "add and remove a single mdns service", %{result: result, service: service} do
    :ok = Configuration.add_mdns_services(service)
    assert result in Configuration.get_mdns_services()

    :ok = Configuration.remove_mdns_services(result.name)
    assert result not in Configuration.get_mdns_services()
  end

  test "add and remove a list of mdns services", %{result: result, service: service} do
    :ok = Configuration.add_mdns_services([service])
    assert result in Configuration.get_mdns_services()

    :ok = Configuration.remove_mdns_services([result.name])
    assert result not in Configuration.get_mdns_services()
  end
end
