import aiohttp
import json
import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.discord_webhook = self.config.get("discord_webhook")

    async def _msg_discord(self, msg: str):
        logger.info(f"dispatching message: {msg}")
        
        async with aiohttp.ClientSession() as session:
            async with session.post(self.discord_webhook, {
                'content': msg
            }) as response:
                if response.status != 200:
                    logger.error(f"discord dispatch returned error {response.status}")

    async def on_state_change(self, key: str, old_value, new_value):
        if key == StateKey.VEHICLE_SAFE and new_value is False:
            await self._msg_discord(":warning: Vehicle has gone AWOL")
