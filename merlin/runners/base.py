import asyncio
import logging

logger = logging.getLogger(__name__)

class BaseRunner:
    def __init__(self, state, mqtt_client, config):
        self.state = state
        self.mqtt = mqtt_client
        self.config = config
        self.interval = config.get("interval", 60)
        self.name = config.get("name", "unnamed_runner")

    async def start(self):
        logger.info("runner '%s' started (interval: %ss)", self.name, self.interval)
        while True:
            try:
                await self.tick()
            except Exception as e:
                logger.error("runner '%s' encountered an error: %s", self.name, e)
            await asyncio.sleep(self.interval)

    async def tick(self):
        pass
