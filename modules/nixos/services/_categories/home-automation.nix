# Home automation and IoT services
# Import this category for smart home control hosts
{ ... }:
{
  imports = [
    ../emqx          # MQTT broker
    ../esphome       # ESPHome firmware builder/dashboard
    ../frigate       # NVR with object detection
    ../home-assistant # Home automation hub
    ../scrypted      # NVR / automation bridge
    ../zigbee2mqtt   # Zigbee gateway
    ../zwave-js-ui   # Z-Wave gateway
  ];
}
