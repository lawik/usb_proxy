NervesMOTD.print()

# Add Toolshed helpers to the IEx session
use Toolshed

alias UsbProxy.Api

IO.puts("""
usbproxy quick reference (same actions as the JSON API and MCP):

  Api.list_devices!()                          all devices, live state
  Api.get_device!("name")                      one device by stable name
  Api.set_exposure!("name", :usbip)            :usbip | :serial | :auto
  Api.switch_mode!("name", "bootloader")       "bootloader" | "app"
  Api.list_serial_consoles!()                  console TCP ports + status
  Api.recover!(:vbus)                          :vbus | :reboot (rate-limited)
  Api.list_recovery_actions!()                 recovery history this boot
  UsbProxy.EventLog.tail(20)                   persistent event log
""")
