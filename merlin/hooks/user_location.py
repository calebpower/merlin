import json
import logging
from merlin.hooks.base import BaseHook

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.user_state = "HOME"
        logger.info("hook 'user_state' loaded")

    async def on_state_change(self, key: str, old_value, new_value):
        if key == "hapn_device_state":
            logger.info(f"vehicle update: {new_value}")
        elif key == "mobile_device_state":
            logger.info(f"mobile device update: {new_value}")
