from merlin.hooks.base import BaseHook
from merlin.state import StateKey

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.alert_topic = self.config.get("alert_topic", "system/state_alerts")
        
    async def on_state_change(self, key: str, old_value, new_value):
        # react to a global state change and publish to MQTT
        if key == StateKey.LAST_MESSAGE:
            msg = f"Alert! State '{key}' changed from '{old_value}' to '{new_value}'"
            await self.mqtt.publish(self.alert_topic, payload=msg)
