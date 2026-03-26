import logging
from merlin.hooks.base import BaseHook

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    async def on_message(self, topic: str, payload: str):
        logger.info("received topic: %s, payload: %s", topic, payload)
        
        # respond directly to an MQTT topic
        if topic == "test/ping":
            await self.mqtt.publish("test/pong", payload="pong")

        # update the global state based on an MQTT message
        if topic == "state/update":
            await self.state.set("last_message", payload)
