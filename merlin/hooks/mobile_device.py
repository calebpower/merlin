import time
import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.state_topic = self.config.get("state_topic", "http/mobile/ariia/state")
        logger.info("hook 'mobile_device' loaded")

    async def on_message(self, topic: str, payload: str):
        logger.info(f"topic: {topic}")
        if topic == self.state_topic:
            await self.state.set(StateKey.MOBILE_DEVICE_STATE, payload)
