import json
import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)


class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.power_topic = self.config.get(
            "power_topic", "bubbles/anycubic_kobra_neo/power"
        )
        self.print_stats_topic = self.config.get(
            "print_stats_topic", "moonraker/status/print_stats"
        )
        logger.info("hook 'klipper_monitor' loaded")

    async def on_message(self, topic: str, payload: str):
        if topic == self.power_topic:
            if payload in ("REBOOT", "OFF", "ON"):
                logger.info("klipper monitor received %s request", payload)
                await self.state.set(StateKey.DEV_3DPRNT_REQ, payload)

        elif topic == self.print_stats_topic:
            try:
                data = json.loads(payload)
                state_val = data.get("state") or data.get("print_stats", {}).get(
                    "state"
                )
                if state_val == "printing":
                    logger.info("klipper monitor detected print starting")
                    await self.state.set(StateKey.DEV_3DPRNT_REQ, "PRINT_STARTING")
                elif state_val in ("complete", "cancelled", "error"):
                    logger.info("klipper monitor detected print complete/stopped")
                    await self.state.set(StateKey.DEV_3DPRNT_REQ, "PRINT_COMPLETE")
            except Exception:
                pass
