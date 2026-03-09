import json
import logging
from src.hooks.base import BaseHook

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.lamp1_state = "OFF"
        self.lamp2_state = "OFF"

    async def on_mqtt_message(self, topic: str, payload: str):
        # track individual lamp states
        try:
            if topic == "zigbee2mqtt/home/living_room/plug/lamp_1":
                data = json.loads(payload)
                if "state" in data:
                    self.lamp1_state = data["state"]
            elif topic == "zigbee2mqtt/home/living_room/plug/lamp_2":
                data = json.loads(payload)
                if "state" in data:
                    self.lamp2_state = data["state"]
        except json.JSONDecodeError:
            pass

    async def on_state_change(self, key: str, old_value, new_value):
        if key == "livingroom_button_single_ts":
            # turn off only if both are currently on; otherwise default to on
            if self.lamp1_state == "ON" and self.lamp2_state == "ON":
                target_state = "OFF"
            else:
                target_state = "ON"

            logger.info("livingroom lamps toggled %s", target_state)

            await self.mqtt.publish(
                "zigbee2mqtt/living_room_lamps/set",
                payload=json.dumps({"state": target_state})
            )
