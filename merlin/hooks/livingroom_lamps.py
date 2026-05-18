import json
import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey
from pydantic import BaseModel

logger = logging.getLogger(__name__)


class LampState(BaseModel):
    state: str | None = None


class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.lamp1_state = "OFF"
        self.lamp2_state = "OFF"
        self.lamp1_topic = self.config.get(
            "lamp1_topic", "zigbee2mqtt/home/living_room/plug/lamp_1"
        )
        self.lamp2_topic = self.config.get(
            "lamp2_topic", "zigbee2mqtt/home/living_room/plug/lamp_2"
        )
        self.set_topic = self.config.get(
            "set_topic", "zigbee2mqtt/living_room_lamps/set"
        )
        logger.info("hook 'livingroom_lamps' loaded")

    async def _toggle_lamps(self, target_state=None):
        if target_state is None:
            target_state = (
                "OFF" if self.lamp1_state == "ON" and self.lamp2_state == "ON" else "ON"
            )
        logger.info("livingroom lamps toggled %s", target_state)
        await self.mqtt.publish(
            self.set_topic, payload=json.dumps({"state": target_state})
        )

    async def on_message(self, topic: str, payload: str):
        # track individual lamp states
        try:
            if topic == self.lamp1_topic:
                data = LampState.model_validate_json(payload)
                if data.state:
                    self.lamp1_state = data.state
                    logger.info(
                        "detected updated state for living room lamp no. 1: %s",
                        self.lamp1_state,
                    )
            elif topic == self.lamp2_topic:
                data = LampState.model_validate_json(payload)
                if data.state:
                    self.lamp2_state = data.state
                    logger.info(
                        "detected updated state for living room lamp no. 2: %s",
                        self.lamp2_state,
                    )
        except Exception:
            pass

    async def on_state_change(self, key: str, old_value, new_value):
        if key in (StateKey.BTN_LVNGRM_SGLCLK, StateKey.BTN_LVNGRM_DBLCLK):
            await self._toggle_lamps()

        elif key == StateKey.USR_LOC_HOME_FLAG and new_value is False:
            await self._toggle_lamps("OFF")
