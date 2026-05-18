import logging
from merlin.hooks.base import BaseHook
from merlin.state import StateKey

logger = logging.getLogger(__name__)

class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.ping_topic = self.config.get("ping_topic", "test/ping")
        self.pong_topic = self.config.get("pong_topic", "test/pong")
        self.update_topic = self.config.get("update_topic", "state/update")
    
    async def on_message(self, topic: str, payload: str):
        logger.info("received topic: %s, payload: %s", topic, payload)
        
        # respond directly to an MQTT topic
        if topic == self.ping_topic:
            await self.mqtt.publish(self.pong_topic, payload="pong")

        # update the global state based on an MQTT message
        if topic == self.update_topic:
            await self.state.set(StateKey.LAST_MESSAGE, payload)
