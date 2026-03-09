class BaseHook:
    def __init__(self, state, mqtt_client, config):
        self.state = state      # GlobalState instance
        self.mqtt = mqtt_client # aiomqtt client
        self.config = config    # specific hook config dict

    async def on_mqtt_message(self, topic: str, payload: str):
        pass # override to handle incoming MQTT messages

    async def on_state_change(self, key: str, old_value, new_value):
        pass # override to react to global state changes
