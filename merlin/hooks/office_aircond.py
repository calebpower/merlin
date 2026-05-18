import json
import logging
from pydantic import BaseModel
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)


class PlugState(BaseModel):
    state: str | None = None


class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.state_topic = self.config.get("state_topic", "home/office/plug/climate")
        self.set_topic = self.config.get("set_topic", "home/office/plug/climate/set")
        self.printer_active = False
        logger.info("hook 'office_aircond' loaded")

    async def _set_power(self, target_state: str):
        logger.info("office aircond power set to %s", target_state)
        await self.mqtt.publish(
            self.set_topic, payload=json.dumps({"state": target_state})
        )

    async def on_message(self, topic: str, payload: str):
        if topic == self.state_topic:
            try:
                data = PlugState.model_validate_json(payload)
                if data.state:
                    if self.printer_active and data.state == "OFF":
                        pass
                    else:
                        await self.state.set(
                            StateKey.DEV_OFFICE_AIRCOND_STATE, data.state
                        )
            except Exception:
                pass

    async def on_state_change(self, key: str, old_value, new_value):
        if key == StateKey.DEV_3DPRNT_REQ:
            if new_value == "PRINT_STARTING":
                self.printer_active = True
                await self._set_power("OFF")
                await self.state.set(StateKey.DEV_3DPRNT_REQ, None)
            elif (
                new_value == "PRINT_COMPLETE"
                or new_value == "OFF"
                or new_value == "REBOOT"
            ):
                self.printer_active = False
                logical_state = self.state.get(StateKey.DEV_OFFICE_AIRCOND_STATE)
                if logical_state == "ON":
                    await self._set_power("ON")

                # allow printer plug hook to manage global state
                # in the event we had a power request or something
                if new_value == "PRINT_COMPLETE":
                    await self.state.set(StateKey.DEV_3DPRNT_REQ, None)
