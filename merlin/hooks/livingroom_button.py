import time
import logging
from merlin.hooks.base import BaseHook

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        logger.info("hook 'livingroom_button' loaded")
    
    async def on_mqtt_message(self, topic: str, payload: str):
        # monitor the specific button topic
        if topic == "zigbee2mqtt/home/living_room/switch/lamps/action":
            if payload == "single":
                logger.info("livingroom button single-pressed")
                await self.state.set("livingroom_button_single_ts", time.time())

            elif payload == "double":
                logger.info("livingroom button double-pressed")
                await self.state.set("livingroom_button_double_ts", time.time())
