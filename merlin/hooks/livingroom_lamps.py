import json
import logging
from merlin.hooks.base import BaseHook

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.lamp1_state = "OFF"
        self.lamp2_state = "OFF"
        logger.info("hook 'livingroom_lamps' loaded")

    async def _toggle_lamps(target_state=None):
        if target_state == None:
            target_state = "OFF" if self.lamp1_state == "ON" and self.lamp2_state == "ON" else "ON"
        logger.info("livingroom lamps toggled %s", target_state)
        await self.mqtt.publish(
            "zigbee2mqtt/living_room_lamps/set",
            payload=json.dumps({"state": target_state})
        )

    async def on_message(self, topic: str, payload: str):
        # track individual lamp states
        try:
            if topic == "zigbee2mqtt/home/living_room/plug/lamp_1":
                data = json.loads(payload)
                if "state" in data:
                    self.lamp1_state = data["state"]
                    logger.info("detected updated state for living room lamp no. 1: %s", self.lamp1_state)
            elif topic == "zigbee2mqtt/home/living_room/plug/lamp_2":
                data = json.loads(payload)
                if "state" in data:
                    self.lamp2_state = data["state"]
                    logger.info("detected updated state for living room lamp no. 2: %s", self.lamp2_state)
        except json.JSONDecodeError:
            pass

    async def on_state_change(self, key: str, old_value, new_value):
        if key == "livingroom_button_single_ts" or key == "livingroom_button_double_ts":
            _toggle_lamps()

        elif key == "user:at_home":
            _toggle_lamps("OFF")
