import aiohttp
import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)


class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.discord_webhook = self.config.get("discord_webhook")
        self.presence_alert_fired = False

    async def _msg_discord(self, msg: str):
        logger.info(f"dispatching message: {msg}")

        async with aiohttp.ClientSession() as session:
            async with session.post(
                self.discord_webhook, json={"content": msg}
            ) as response:
                if response.status != 200:
                    logger.error(f"discord dispatch returned error {response.status}")

    async def on_state_change(self, key: str, old_value, new_value):
        if key == StateKey.DEV_VEHICLE_SAFE_FLAG and new_value is False:
            await self._msg_discord(":warning: Vehicle has gone AWOL")

        elif key == StateKey.USR_LOC_HOME_FLAG:
            if new_value is True:
                self.presence_alert_fired = False

        elif key == StateKey.SNS_HOME_PRESENCE:
            if (
                self.state.get(StateKey.USR_LOC_HOME_FLAG) is False
                and not self.presence_alert_fired
            ):
                self.presence_alert_fired = True
                await self._msg_discord(
                    ":warning: Unexpected presence detected at home!"
                )
