import aiohttp
import logging
from merlin.runners.base import BaseRunner
from merlin.state import StateKey

logger = logging.getLogger(__name__)

class Runner(BaseRunner):
    async def tick(self):
        # access custom config values directly
        endpoint = self.config.get("endpoint")
        api_key = self.config.get("api_key")

        # example http poll
        async with aiohttp.ClientSession() as session:
            async with session.get(f"{endpoint}?key={api_key}") as response:
                data = await response.json()
                
                # update state
                await self.state.set(StateKey.WEATHER_TEMP, data["temp"])
                logger.info("updated weather_temp state")
