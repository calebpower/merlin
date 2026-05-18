import time
import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.button_topic = self.config.get("button_topic", "zigbee2mqtt/home/living_room/switch/lamps/action")
        logger.info("hook 'livingroom_button' loaded")
    
    async def on_message(self, topic: str, payload: str):
        # monitor the specific button topic
        if topic == self.button_topic:
            if payload == "single":
                logger.info("livingroom button single-pressed")
                await self.state.set(StateKey.LIVINGROOM_BUTTON_SINGLE_TS, time.time())

            elif payload == "double":
                logger.info("livingroom button double-pressed")
                await self.state.set(StateKey.LIVINGROOM_BUTTON_DOUBLE_TS, time.time())
