import aiohttp
import logging
from datetime import datetime, timedelta
from merlin.runners.base import BaseRunner

logger = logging.getLogger(__name__)

class Runner(BaseRunner):

    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)
        self.last_run = None
        self.bearer_token = None
    
    async def tick(self):
        now = datetime.now()
        
        if self.bearer_token is None or self.last_run is None or timedelta(minutes=55) + self.last_run < now:
            logger.info("refreshing hapn bearer token")

            auth_endpoint = self.config.get("auth_endpoint")
            auth_payload = {
                'grant_type': 'client_credentials',
                'client_id': self.config.get("client_id"),
                'client_secret': self.config.get("client_secret")
            }

            async with aiohttp.ClientSession() as session:
                async with session.post(auth_endpoint, data=auth_payload) as response:
                    if response.status != 200:
                        logger.error(f"hapn auth endpoint failed with status {response.status}")
                        self.bearer_token = None

                    else:
                        res_json = await response.json()
                        self.bearer_token = res_json.get("access_token")

        if self.bearer_token is None:
            logger.error("missing bearer token")

        else:
            logger.info("pulling latest info from device")

            device_endpoint = self.config.get("device_endpoint")
            headers = {
                'Accept': 'application/json',
                'Authorization': f'Bearer {self.bearer_token}'
            }

            async with aiohttp.ClientSession() as session:
                async with session.get(device_endpoint, headers=headers) as response:
                    if response.status == 403:
                        logger.error(f"hapn bearer token expired; forcing refresh on next tick")
                        self.bearer_token = None
                        
                    if response.status != 200:
                        logger.error(f"hapn device endpoint failed with status {response.status}")

                    else:
                        res_json = await response.json()
                        result = res_json.get("result")
                        hook_payload = {
                            "gps_time_utc": result.get("gpsUTCTime"),
                            "gps_accuracy": result.get("gpsAccuracy"),
                            "battery_percentage": result.get("batteryPercentage"),
                            "send_time": result.get("sendTime"),
                            "physical_address": result.get("address"),
                            "azimuth": result.get("azimuth"),
                            "longitude": result.get("longitude"),
                            "latitude": result.get("latitude"),
                            "mileage": result.get("odoMileage"),
                            "speed": result.get("speed")
                        }
                        await self.state.set("hapn_device_state", hook_payload)

                        logger.info("updated vehicle tracking state")

        self.last_run = now
