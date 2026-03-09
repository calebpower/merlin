from merlin.hooks.base import BaseHook

class Hook(BaseHook):
    async def on_state_change(self, key: str, old_value, new_value):
        # react to a global state change and publish to MQTT
        if key == "last_message":
            msg = f"Alert! State '{key}' changed from '{old_value}' to '{new_value}'"
            await self.mqtt.publish("system/state_alerts", payload=msg)
