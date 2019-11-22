defmodule MdnsLite.InetMonitorTest do
  use ExUnit.Case, async: true

  alias MdnsLite.{InetMonitor, ResponderSupervisor}

  test "can add and remove IP for monitor" do
    new_ip = {'wlan0', {127, 0, 0, 2}}

    responders = Supervisor.count_children(ResponderSupervisor).specs

    :ok = InetMonitor.add(new_ip)

    assert new_ip in :sys.get_state(InetMonitor).ip_list
    assert Supervisor.count_children(ResponderSupervisor).active == responders + 1

    # remove the IP address
    :ok = InetMonitor.remove(new_ip)

    assert new_ip not in :sys.get_state(InetMonitor).ip_list
  end

  test "cannot add with bad ip_list" do
    bad = [{'wlan', :wat}]

    assert InetMonitor.add(bad) == {:error, :invalid_ip}
  end
end
