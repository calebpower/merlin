import time
import json
import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)


class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.topic_pattern = self.config.get("topic_pattern", "home/+/sensor/contact")
        logger.info("hook 'home_doors' loaded")

    async def on_message(self, topic: str, payload: str):
        pattern_parts = self.topic_pattern.split("/")
        topic_parts = topic.split("/")

        if len(pattern_parts) != len(topic_parts):
            return

        match = True
        room = "unknown"
        for p, t in zip(pattern_parts, topic_parts):
            if p == "+":
                room = t
            elif p != t:
                match = False
                break

        if not match:
            return

        try:
            data = json.loads(payload)
            if "contact" in data:
                door_val = "CLOSED" if data["contact"] else "OPEN"
            elif "state" in data:
                door_val = "OPEN" if data["state"] == "ON" else "CLOSED"
            else:
                door_val = "UNKNOWN"

            logger.info("door in %s is %s", room, door_val)

            current_state_str = self.state.get(StateKey.SNS_HOME_DOORS_STATE)
            current_list = json.loads(current_state_str) if current_state_str else []

            state_dict = {}
            for item in current_list:
                for k, v in item.items():
                    state_dict[k] = v

            old_val = state_dict.get(room)
            if old_val != door_val:
                state_dict[room] = door_val
                new_list = [{k: v} for k, v in state_dict.items()]
                new_state_str = json.dumps(new_list)

                await self.state.set(StateKey.SNS_HOME_DOORS_STATE, new_state_str)
                await self.state.set(StateKey.SNS_HOME_PRESENCE, time.time())

        except json.JSONDecodeError:
            logger.error("failed to parse door payload as JSON: %s", payload)

        except Exception as e:
            logger.error("error processing door payload: %s", e)
